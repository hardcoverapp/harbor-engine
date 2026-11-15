require "test_helper"

# A Conductor Cloud runtime: the form, the list and its own page in a site
# with no code of its own, and what the backend says about readiness, health
# and models.
class HarborConductorCloudRuntimeTest < ActionDispatch::IntegrationTest
  include HarborTestConfig
  include HarborConductorCloud

  Backend = Harbor::Runtimes::Backends::ConductorCloud

  setup do
    [ Harbor::Agent, Harbor::WorkspaceProfileRuntime, Harbor::WorkspaceProfile, Harbor::Run, Harbor::Runtime,
      Harbor::ModelChoice, Harbor::ModelAlias, Harbor::ModelProvider ].each(&:delete_all)
    # The form also draws Orca's kinds, which ask Orca for their lists.
    Harbor::Orca.runner = ->(_argv, timeout:) { [ "", "no Orca here", 1 ] }
    post "/login", params: { name: "Sam Settings" }
  end

  teardown do
    Harbor::Orca.runner = nil
    ENV.delete("ACME_CONDUCTOR_KEY")
  end

  def fields(**values) = { "conductor_cloud" => { repository_url: "https://github.com/acme/app" }.merge(values) }

  test "the new runtime form offers Conductor Cloud as a third kind, with fields and no JSON" do
    get harbor.new_runtime_path
    assert_response :success
    assert_equal [ "orca", "orca:remote", "conductor_cloud" ], css_select("input[name='runtime[type]']").map { |input| input["value"] }
    assert_select "[data-runtime-choice=conductor_cloud]", text: /Conductor Cloud\s+Work runs in a Conductor Cloud workspace, made for each run from the repository\./
    assert_select "[data-choice=conductor_cloud]" do
      assert_select "input[name='runtime[fields][conductor_cloud][repository_url]'][required]"
      assert_select "input[name='runtime[fields][conductor_cloud][branch]']"
      assert_select "details input[name='runtime[fields][conductor_cloud][api_key_env]'][placeholder=CONDUCTOR_API_KEY]"
      assert_select "details input[name='runtime[fields][conductor_cloud][api_url]'][placeholder='https://api.conductor.build']"
      assert_select "textarea", count: 0
      assert_select "[data-conductor-key]", text: /read from the environment variable CONDUCTOR_API_KEY, which is set/
    end
    assert_no_match "test-conductor-key", response.body, "the key is never on the page"
  end

  test "a site with no code of its own adds a Conductor Cloud runtime, and the list and its page show it" do
    assert_difference("Harbor::Runtime.count", 1) do
      post harbor.runtimes_path, params: { runtime: { name: "Conductor", type: "conductor_cloud", max_concurrent: 3, enabled: "1",
                                                      fields: fields(branch: " main ") } }
    end
    assert_redirected_to harbor.runtimes_path
    added = Harbor::Runtime.find_by!(key: "conductor")
    assert_equal [ "conductor_cloud", 3, true, nil, { "repository_url" => "https://github.com/acme/app", "branch" => "main" } ],
                 [ added.backend, added.max_concurrent, added.enabled, added.host, added.config ]
    assert_equal [ Backend, "Conductor Cloud", "acme/app" ], [ added.backend_class, added.adapter.label, added.adapter.place ]
    assert_nil added.unavailable_reason
    assert_no_match "test-conductor-key", added.attributes.to_json, "the key is not stored"

    follow_redirect!
    assert_select "tr[data-runtime=conductor][data-state=ok]" do
      assert_select "[data-status]", text: "Taking work"
      assert_select "p", text: "Conductor Cloud · acme/app"
      assert_select "[data-busy]", text: "0 / 3"
    end

    get harbor.edit_runtime_path(added)
    assert_response :success
    assert_select "h1", "Conductor"
    assert_select "[data-runtime-health]", text: /Taking new work/
    assert_equal [ "conductor_cloud" ], css_select("input[name='runtime[type]']").map { |input| input["value"] }
    assert_select "input[name='runtime[fields][conductor_cloud][repository_url]'][value='https://github.com/acme/app']"
    assert_select "input[name='runtime[fields][conductor_cloud][branch]'][value=main]"
    assert_no_match "test-conductor-key", response.body
  end

  test "it is edited on its own page: another repository, and a key variable and API address of its own" do
    runtime = cloud_runtime
    patch harbor.runtime_path(runtime), params: { runtime: { name: "Cloud", type: "conductor_cloud", max_concurrent: 4, enabled: "1",
      fields: fields(repository_url: "https://github.com/acme/shop.git", api_key_env: "ACME_CONDUCTOR_KEY", api_url: "https://conductor.acme.test/") } }
    assert_redirected_to harbor.runtimes_path
    assert_equal({ "repository_url" => "https://github.com/acme/shop.git", "api_key_env" => "ACME_CONDUCTOR_KEY", "api_url" => "https://conductor.acme.test" },
                 runtime.reload.config)
    assert_equal [ 4, "acme/shop" ], [ runtime.max_concurrent, runtime.adapter.place ]
    assert_equal "the Conductor API key isn't set (ACME_CONDUCTOR_KEY)", runtime.unavailable_reason, "it takes no work, and says which variable"

    follow_redirect!
    assert_select "tr[data-runtime=cloud][data-state=warning]", text: /The Conductor API key isn't set \(ACME_CONDUCTOR_KEY\)/
    get harbor.edit_runtime_path(runtime)
    assert_select "[data-conductor-key]", text: /ACME_CONDUCTOR_KEY, which is not set here/
    assert_select "input[name='runtime[fields][conductor_cloud][api_key_env]'][value=ACME_CONDUCTOR_KEY]"

    ENV["ACME_CONDUCTOR_KEY"] = "another-secret"
    assert_nil runtime.reload.unavailable_reason
    runtime.adapter.health_check
    assert_equal "Bearer another-secret", @conductor.requests.last.headers["authorization"]

    patch harbor.runtime_path(runtime), params: { runtime: { name: "Cloud", type: "conductor_cloud", max_concurrent: 4, enabled: "1",
      fields: fields(api_key_env: "CONDUCTOR_API_KEY", api_url: "https://api.conductor.build") } }
    assert_equal({ "repository_url" => "https://github.com/acme/app" }, runtime.reload.config, "the defaults are not written down")
  end

  test "what can't be used is said, with what was typed still there, and a key typed where its variable goes is refused" do
    wrong = { { repository_url: "" } => /Give the address of the repository/,
              { repository_url: "git@github.com:acme/app.git" } => /starts with https:/,
              { api_key_env: "ck_live_abcdef" } => /named by an environment variable, like CONDUCTOR_API_KEY, not typed here/,
              { api_url: "conductor.acme.test" } => /The API's address starts with https:/ }
    wrong.each do |values, message|
      assert_no_difference("Harbor::Runtime.count") do
        post harbor.runtimes_path, params: { runtime: { name: "Conductor", type: "conductor_cloud", max_concurrent: 1, fields: fields(branch: "main", **values) } }
      end
      assert_response :unprocessable_entity
      assert_select "[role=alert]", text: message
      assert_select "input[name='runtime[type]'][value=conductor_cloud][checked]"
      assert_select "input[name='runtime[fields][conductor_cloud][branch]'][value=main]"
    end
  end

  test "readiness: no key, or no repository, takes no work" do
    runtime = cloud_runtime
    assert_nil runtime.adapter.unready_reason
    assert_empty runtime.adapter.warnings
    ENV.delete("CONDUCTOR_API_KEY")
    assert_equal "the Conductor API key isn't set (CONDUCTOR_API_KEY)", runtime.adapter.unready_reason
    ENV["CONDUCTOR_API_KEY"] = "test-conductor-key"
    assert_equal "no repository set", cloud_runtime(key: "bare", name: "Bare", config: {}).adapter.unready_reason
    assert_nil Harbor::Setting.get(:runner_url).presence, "and it needs no runner address"
  end

  test "the health check is one read-only call, and its result is recorded" do
    runtime = cloud_runtime
    post harbor.check_runtime_path(runtime)
    assert_equal "Cloud is healthy.", flash[:notice]
    assert_equal [ "GET /v0/sections" ], @conductor.sent
    assert_equal({ "offset" => "0", "limit" => "1" }, @conductor.requests.last.params)

    @conductor.refuse("GET /v0/sections", code: 401, message: "bad key")
    post harbor.check_runtime_path(runtime)
    assert_match "Cloud failed its health check: Error: Conductor GET /v0/sections → 401: bad key", flash[:alert]
    assert_match "unhealthy", runtime.reload.unavailable_reason

    ENV.delete("CONDUCTOR_API_KEY")
    @conductor.requests.clear
    error = assert_raises(RuntimeError) { runtime.adapter.health_check }
    assert_match "the Conductor API key isn't set (CONDUCTOR_API_KEY)", error.message
    assert_empty @conductor.requests
  end

  test "it runs the models Conductor has, and placement passes over one it hasn't" do
    anthropic = Harbor::ModelProvider.create!(key: "anthropic")
    choice = ->(model) { Harbor::ModelChoice.new(model_provider: anthropic, model:) }
    assert Backend.supports?(choice.("claude-sonnet-5-5"))
    assert Backend.supports?(choice.("claude-opus-5-5"), allowed_tools: %w[Read], disallowed_tools: %w[Bash])
    assert_not Backend.supports?(choice.("claude-opus-4-5"))
    assert_equal "sonnet-5-5-1m", Backend.model_id_for("claude-sonnet-5-5")
    assert_equal [ true, false, true ], [ Backend.keeps_workspaces?, Backend.enforces_tool_policy?, Backend.agent_sessions? ]

    models = Harbor::ModelAlias.create!(name: "Mixed", model_choices_attributes: [
      { model_provider: anthropic, model: "claude-opus-4-5", position: 0 }, { model_provider: anthropic, model: "claude-opus-5-5", position: 1 } ])
    workspace = Harbor::WorkspaceProfile.create!(name: "Cloud first", workspace_profile_runtimes_attributes: [ { runtime: cloud_runtime, position: 0 } ])
    agent = Harbor::Agent.create!(key: "writer", name: "Writer", model_alias: models, workspace_profile: workspace)
    placement = agent.placement
    assert_equal [ "cloud", "claude-opus-5-5" ], [ placement.runtime.key, placement.choice.model ]
    error = assert_raises(Harbor::WorkspaceProfile::Unavailable) { agent.placement(requirements: { tool_policy: true }) }
    assert_match "Cloud: can't enforce this work's tool policy", error.message, "work that needs its tool rules enforced is not placed here"
  end
end
