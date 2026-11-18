require "test_helper"

class HarborRuntimePagesTest < ActionDispatch::IntegrationTest
  include HarborTestConfig

  class PageBackend < Harbor::Runtimes::Backend
    class << self
      attr_accessor :healthy, :offered
      def label = "Page test"
      def offered? = offered != false
    end
    def health_check = self.class.healthy ? true : raise("no answer")
    def warnings = [ "Check the cable." ]
  end

  setup do
    [ Harbor::Agent, Harbor::WorkspaceProfileRuntime, Harbor::WorkspaceProfile, Harbor::Run, Harbor::Runtime ].each(&:delete_all)
    Harbor::Runtimes.register "page", "HarborRuntimePagesTest::PageBackend"
    PageBackend.healthy = true
    HARBOR_TEST_REDIS.with { |r| r.call("KEYS", "harbor:test:slots:*").each { |k| r.call("DEL", k) } }
    @cloud = Harbor::Runtime.create!(key: "cloud", name: "Cloud", backend: "page", max_concurrent: 3, position: 0, host: "cloud.example")
    @laptop = Harbor::Runtime.create!(key: "laptop", name: "Laptop", backend: "page", max_concurrent: 2, position: 1)
    @workspace = Harbor::WorkspaceProfile.create!(name: "Default", description: "Cloud first",
                                                  workspace_profile_runtimes_attributes: [ { runtime: @cloud, position: 0 }, { runtime: @laptop, position: 1 } ])
    @changes = 0
    Harbor.config.availability_changed = -> { @changes += 1 }
    post "/login", params: { name: "Sam Settings" }
  end

  teardown do
    Harbor::Runtimes.unregister "page"
    Harbor.config.availability_changed = nil
  end

  # Answers the Orca commands the runtime form asks: its repos, hosts and
  # projects, as Orca 1.4.257 gives them.
  class ListingOrca
    attr_reader :commands, :argvs
    attr_accessor :down

    def initialize
      @commands = []
      @argvs = []
    end

    def call(argv, timeout:)
      @argvs << argv
      @commands << argv[1, 2].join(" ")
      return [ "", "orca: not running", 1 ] if down
      result = case argv[1, 2].join(" ")
      when "repo list" then { "repos" => [ { "id" => "r-1", "displayName" => "app", "path" => "/code/app" } ] }
      when "host list"
        { "hosts" => [ { "kind" => "local", "name" => "this machine", "id" => "local" },
                       { "kind" => "ssh", "name" => "droplet-1", "id" => "ssh-1", "connected" => true },
                       { "kind" => "ssh", "name" => "droplet-2", "id" => "ssh-2", "connected" => false } ] }
      when "project list" then { "projects" => [ { "id" => "github:acme/app", "displayName" => "App" } ] }
      when /\Astatus/ then { "runtime" => { "appVersion" => "1.4.257", "state" => "ready" } }
      else {}
      end
      [ JSON.generate("ok" => true, "result" => result), "", 0 ]
    end
  end

  def with_orca(down: false)
    Harbor::Orca.runner = ListingOrca.new.tap { |orca| orca.down = down }
    yield Harbor::Orca.runner
  ensure
    Harbor::Orca.runner = nil
  end

  test "the runtimes page is a table: each runtime's status, kind, use, workspaces and last check" do
    Harbor::Runtimes::Slots.acquire(@cloud, "run-1", ttl: 60)
    @laptop.update!(enabled: false)
    Harbor::Runtime.create!(name: "Broken", backend: "orca", config: {})
    get harbor.runtimes_path
    assert_response :success
    assert_select "table thead th", text: "Status"
    assert_select "tr[data-runtime=cloud][data-state=ok]" do
      assert_select "[data-status]", text: "Taking work"
      assert_select "[data-status] svg.harbor-icon"
      assert_select "a[href=?]", harbor.edit_runtime_path(@cloud), text: "Cloud"
      assert_select "p", text: "Page test · cloud.example"
      assert_select "[data-busy]", text: "1 / 3"
      assert_select "[data-health]", text: "Taking new work"
      assert_select "[data-workspaces]", text: /Default/
      assert_select "p", text: "Check the cable."
      assert_select "a[href=?]", harbor.edit_runtime_path(@cloud), text: "Edit"
    end
    assert_select "tr[data-runtime=laptop][data-state=off] [data-status]", text: "Off"
    assert_select "tr[data-runtime=broken][data-state=warning]" do
      assert_select "[data-status]", text: "Not taking work"
      assert_select "p", text: "No repository set"
      assert_select "p", text: "Orca · This server"
      assert_select "[data-workspaces]", text: /None yet/
    end
    assert_select "[data-controller='harbor--poll']"
    assert_select "[data-harbor-nav] a[aria-current=page]", text: "Runtimes"
  end

  test "a runtime is switched off, limited and configured with single values" do
    patch harbor.runtime_path(@cloud), params: { runtime: { enabled: false } }
    assert_redirected_to harbor.runtimes_path
    assert_not @cloud.reload.enabled?
    assert_equal 1, @changes, "the host is told availability changed"
    follow_redirect!
    assert_select "[data-runtime=cloud] [data-health]", text: "Not taking new work: disabled"

    patch harbor.runtime_path(@laptop), params: { runtime: { max_concurrent: 7 } }
    assert_equal 7, @laptop.reload.max_concurrent
    patch harbor.runtime_path(@laptop), params: { runtime: { max_concurrent: 0 } }
    assert_equal 7, @laptop.reload.max_concurrent
    assert_match "greater than 0", flash[:alert]

    patch harbor.runtime_path(@laptop), params: { runtime: { config: '{"repo": "name:app"}', name: "Sam's laptop" } }
    assert_equal({ "repo" => "name:app" }, @laptop.reload.config)
    assert_equal "Sam's laptop", @laptop.name
    patch harbor.runtime_path(@laptop), params: { runtime: { config: "[1]" } }
    assert_equal "Config must be a JSON object.", flash[:alert]
    patch harbor.runtime_path(@laptop), params: { runtime: { config: "{not json" } }
    assert_equal "Config must be valid JSON.", flash[:alert]
    assert_equal({ "repo" => "name:app" }, @laptop.reload.config)
  end

  test "the new runtime form offers Orca and Orca (Remote), with lists from Orca and no key to think up" do
    with_orca do
      get harbor.new_runtime_path
      assert_response :success
      assert_select "input[name='runtime[key]']", count: 0
      assert_select "[data-runtime-choice=orca]", text: /Orca\s+Work runs on this server/
      assert_select "[data-runtime-choice='orca:remote']", text: /Orca \(Remote\)\s+Orca still runs on this server/
      assert_select "input[name='runtime[type]'][value=orca][checked]"
      assert_select "[data-choice=orca]:not([hidden]) select[name='runtime[fields][orca][repo]'] option[value='id:r-1']", text: "app · /code/app"
      assert_select "[data-choice='orca:remote'][hidden]" do
        assert_select "select[name='runtime[fields][orca:remote][provider]'] option[value=digitalocean]", text: "DigitalOcean"
        assert_select "select[name='runtime[fields][orca:remote][host]'] option", count: 3, message: "a blank and the two SSH hosts, not this machine"
        assert_select "select[name='runtime[fields][orca:remote][host]'] option[value='ssh:ssh-2']", text: "droplet-2 (not connected)"
        assert_select "select[name='runtime[fields][orca:remote][project]'] option[value='github:acme/app']", text: "App"
      end
      assert_select "[data-choice=page] textarea[name='runtime[fields][page][config]']"
    end
  end

  test "an Orca runtime is added for a repository on this server, its key made from its name" do
    with_orca do
      assert_difference("Harbor::Runtime.count", 1) do
        post harbor.runtimes_path, params: { runtime: { name: "Sam's laptop", type: "orca", max_concurrent: 2, enabled: "1",
                                                        fields: { "orca" => { repo: "id:r-1", setup: "run", environment: "sam" },
                                                                  "orca:remote" => { host: "ssh:ssh-1", project: "ignored" } } } }
      end
    end
    assert_redirected_to harbor.runtimes_path
    added = Harbor::Runtime.find_by!(key: "sam-s-laptop")
    assert_equal [ "Sam's laptop", "orca", 2, true, { "repo" => "id:r-1", "setup" => "run", "environment" => "sam" } ],
                 [ added.name, added.backend, added.max_concurrent, added.enabled, added.config ]
    assert_equal [ "Orca", "sam", false ], [ added.adapter.label, added.adapter.place, added.adapter.remote? ]
    assert_operator added.position, :>, @laptop.position, "a new runtime goes last"
    assert_empty added.workspace_profiles, "and takes no work until a workspace lists it"
    assert_equal 0, @changes, "so nothing waiting is told to look again"
  end

  test "an Orca (Remote) runtime needs its external host, who hosts it and a project" do
    with_orca do
      remote = { provider: "digitalocean", host: "ssh:ssh-1", project: "github:acme/app" }
      { host: /Choose the external host/, provider: /Choose who hosts/, project: /Choose the project/ }.each do |missing, message|
        assert_no_difference("Harbor::Runtime.count") do
          post harbor.runtimes_path, params: { runtime: { name: "Droplet", type: "orca:remote", max_concurrent: 1, fields: { "orca:remote" => remote.except(missing) } } }
        end
        assert_response :unprocessable_entity
        assert_select "[role=alert]", text: message
        assert_select "input[name='runtime[type]'][value='orca:remote'][checked]", true, "the form comes back on the kind that was chosen"
        assert_select "input[name='runtime[name]'][value=Droplet]"
      end
      assert_select "select[name='runtime[fields][orca:remote][host]'] option[selected][value='ssh:ssh-1']", true, "with what was sent still filled in"

      post harbor.runtimes_path, params: { runtime: { name: "Droplet", type: "orca:remote", max_concurrent: 1, enabled: "1", fields: { "orca:remote" => remote } } }
      assert_redirected_to harbor.runtimes_path
    end
    added = Harbor::Runtime.find_by!(key: "droplet")
    assert_equal({ "provider" => "digitalocean", "host" => "ssh:ssh-1", "host_name" => "droplet-1", "project" => "github:acme/app" }, added.config)
    assert_equal [ "Orca (Remote)", "DigitalOcean · droplet-1", true ], [ added.adapter.label, added.adapter.place, added.adapter.remote? ]
    assert_equal({ project: "github:acme/app", host: "ssh:ssh-1" }, added.adapter.worktree_place)
  end

  test "when Orca doesn't answer, the form says so and takes what is typed" do
    with_orca(down: true) do
      get harbor.new_runtime_path
      assert_select "[data-choice=orca] [data-orca-unreachable]", text: /Orca on this server didn't answer/
      assert_select "input[type=text][name='runtime[fields][orca][repo]']"
      assert_select "input[type=text][name='runtime[fields][orca:remote][host]']"
      post harbor.runtimes_path, params: { runtime: { name: "Typed", type: "orca:remote", max_concurrent: 1,
                                                      fields: { "orca:remote" => { provider: "digitalocean", host: "ssh-9", project: "app" } } } }
    end
    assert_equal({ "provider" => "digitalocean", "host" => "ssh:ssh-9", "project" => "app" }, Harbor::Runtime.find_by!(key: "typed").config)
  end

  test "an Orca server is reached by a pairing code held in an environment variable, which the runtime only names" do
    with_orca do
      get harbor.new_runtime_path
      assert_select "input[name='runtime[fields][orca][pairing_code_env]']"
      post harbor.runtimes_path, params: { runtime: { name: "Typed code", type: "orca", max_concurrent: 1,
                                                      fields: { "orca" => { repo: "id:r-1", pairing_code_env: "orca://pair?code=abc" } } } }
      assert_response :unprocessable_entity
      assert_select "[role=alert]", text: /takes the name of an environment variable/
      post harbor.runtimes_path, params: { runtime: { name: "Cloud Orca", type: "orca", max_concurrent: 1, enabled: "1",
                                                      fields: { "orca" => { repo: "id:r-1", pairing_code_env: "HARBOR_TEST_ORCA_CODE" } } } }
    end
    runtime = Harbor::Runtime.find_by!(key: "cloud-orca")
    assert_equal({ "repo" => "id:r-1", "pairing_code_env" => "HARBOR_TEST_ORCA_CODE" }, runtime.config)
    assert_equal "the Orca server's pairing code isn't set (HARBOR_TEST_ORCA_CODE)", runtime.unavailable_reason
    ENV["HARBOR_TEST_ORCA_CODE"] = "orca://pair?code=abc"
    Harbor::Setting.set!(:runner_url, "https://harbor.example.com")
    assert_nil runtime.unavailable_reason
    assert_equal "Orca server (HARBOR_TEST_ORCA_CODE)", runtime.adapter.place
    seen = []
    Harbor::Orca.runner = ->(argv, timeout:) { seen << argv; [ JSON.generate("ok" => true, "result" => { "runtime" => { "state" => "ready" } }), "", 0 ] }
    runtime.adapter.health_check
    assert_equal [ "--pairing-code", "orca://pair?code=abc" ], seen.last.last(2)
  ensure
    ENV.delete("HARBOR_TEST_ORCA_CODE")
    Harbor::Setting.where(key: "runner_url").delete_all
    Harbor::Orca.runner = nil
  end

  CODE = "orca://pair?code=eyJzZWNyZXQiOiJub3QtZm9yLWxvZ3MifQ".freeze

  test "an Orca server is added from the page by pasting its pairing code, which is kept encrypted and never shown" do
    with_orca do |orca|
      get harbor.new_runtime_path
      assert_select "input[type=password][name='runtime[fields][orca][pairing_code]'][autocomplete=off]"

      # Saved with the code and no repository yet: the server's own are listed next.
      post harbor.runtimes_path, params: { runtime: { name: "Sam's Orca", type: "orca", max_concurrent: 2, enabled: "1",
                                                      fields: { "orca" => { pairing_code: " #{CODE} " } } } }
      assert_redirected_to harbor.runtimes_path
      runtime = Harbor::Runtime.find_by!(key: "sam-s-orca")
      assert_equal CODE, runtime.secret
      assert runtime.secret_set_at
      assert_equal({}, runtime.config, "the code is not in the config")
      raw = Harbor::Runtime.connection.select_one("SELECT * FROM runtimes WHERE id = #{runtime.id}")
      assert_not_includes raw.to_s, CODE, "nor readable anywhere in its row"
      assert_not_includes runtime.inspect, CODE
      assert_not_includes runtime.to_json, CODE
      assert_equal "no repository set", runtime.unavailable_reason
      assert_equal "Orca server paired here", runtime.adapter.place

      # Its page asks that server, with the code, and never shows the code.
      orca.argvs.clear
      get harbor.edit_runtime_path(runtime)
      assert_response :success
      assert_not_includes response.body, CODE
      assert_select "[data-orca-pairing-saved]", text: /A pairing code is saved/
      assert_select "input[name='runtime[fields][orca][pairing_code]']" do |inputs|
        assert_nil inputs.first["value"], "the field comes back empty"
      end
      assert_select "select[name='runtime[fields][orca][repo]'] option[value='id:r-1']", text: "app · /code/app"
      repo_list = orca.argvs.find { |argv| argv[1, 2] == %w[repo list] }
      assert_equal [ "--pairing-code", CODE ], repo_list.last(2), "the lists are that server's"

      # The repository is chosen; nothing else was typed again, and the code stays.
      patch harbor.runtime_path(runtime), params: { runtime: { name: "Sam's Orca", type: "orca", max_concurrent: 2, enabled: "1",
                                                              fields: { "orca" => { repo: "id:r-1", pairing_code: "" } } } }
      assert_redirected_to harbor.runtimes_path
      assert_equal [ CODE, { "repo" => "id:r-1" } ], runtime.reload.then { |r| [ r.secret, r.config ] }
      Harbor::Setting.set!(:runner_url, "https://harbor.example.com")
      assert_nil runtime.unavailable_reason

      orca.argvs.clear
      assert runtime.adapter.health_check
      assert_equal [ "--pairing-code", CODE ], orca.argvs.last.last(2), "and every command carries it, with no restart"
      get harbor.runtimes_path
      assert_not_includes response.body, CODE
    end
  ensure
    Harbor::Setting.where(key: "runner_url").delete_all
  end

  test "a saved pairing code is replaced or forgotten, and one that can't be used is refused without being echoed" do
    with_orca do
      runtime = Harbor::Runtime.create!(name: "Paired", backend: "orca", config: { "repo" => "id:r-1" })
      runtime.update!(secret: CODE)

      patch harbor.runtime_path(runtime), params: { runtime: { name: "Paired", type: "orca", max_concurrent: 1,
                                                              fields: { "orca" => { repo: "id:r-1", pairing_code: "orca://pair?code=second" } } } }
      assert_equal "orca://pair?code=second", runtime.reload.secret

      patch harbor.runtime_path(runtime), params: { runtime: { name: "Paired", type: "orca", max_concurrent: 1,
                                                              fields: { "orca" => { repo: "id:r-1", pairing_code: "two words here" } } } }
      assert_response :unprocessable_entity
      assert_select "[role=alert]", text: /one link with no spaces/
      assert_not_includes response.body, "two words here"
      assert_equal "orca://pair?code=second", runtime.reload.secret, "what was saved is untouched"

      patch harbor.runtime_path(runtime), params: { runtime: { name: "Paired", type: "orca", max_concurrent: 1,
                                                              fields: { "orca" => { repo: "id:r-1", forget_pairing_code: "1" } } } }
      assert_equal [ nil, nil, false ], runtime.reload.then { |r| [ r.secret, r.sealed_secret, r.secret? ] }
      assert_equal "This server", runtime.adapter.place

      # Forgotten, and with no repository given: back to needing one.
      patch harbor.runtime_path(runtime), params: { runtime: { name: "Paired", type: "orca", max_concurrent: 1, fields: { "orca" => { repo: "" } } } }
      assert_select "[role=alert]", text: /Choose the repository to work in/
    end
  end

  test "a code saved under another secret key is said to be unreadable, and the request's parameters are logged without it" do
    runtime = Harbor::Runtime.create!(name: "Stale", backend: "orca", config: { "repo" => "id:r-1" })
    other = ActiveSupport::MessageEncryptor.new(SecureRandom.bytes(32))
    runtime.update_columns(sealed_secret: other.encrypt_and_sign(CODE, purpose: Harbor::Runtime::SECRET_PURPOSE))
    assert runtime.secret_unreadable?
    assert_match "can't be read by this app", runtime.unavailable_reason
    with_orca do
      get harbor.edit_runtime_path(runtime)
      assert_select "[data-orca-pairing-saved]", text: /can no longer read it/
    end

    filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
    logged = filter.filter("runtime" => { "fields" => { "orca" => { "pairing_code" => CODE.dup, "repo" => "id:r-1" } } })
    assert_equal({ "pairing_code" => "[FILTERED]", "repo" => "id:r-1" }, logged.dig("runtime", "fields", "orca"))
  end

  test "a second runtime of the same name gets a key of its own" do
    with_orca do
      2.times { post harbor.runtimes_path, params: { runtime: { name: "Cloud", type: "orca", max_concurrent: 1, fields: { "orca" => { repo: "id:r-1" } } } } }
    end
    assert_equal %w[cloud cloud-2 cloud-3], Harbor::Runtime.where(name: "Cloud").order(:id).pluck(:key)
  end

  test "a runtime that isn't valid is shown again with what is wrong, and nothing is added" do
    assert_no_difference("Harbor::Runtime.count") do
      post harbor.runtimes_path, params: { runtime: { name: "", type: "nope", max_concurrent: 0 } }
      assert_response :unprocessable_entity
      assert_select "[role=alert]", text: /Choose what kind of runtime this is/

      post harbor.runtimes_path, params: { runtime: { name: "", type: "page", max_concurrent: 0 } }
      assert_response :unprocessable_entity
      assert_select "[role=alert]", text: /Name can't be blank.*greater than 0/m

      post harbor.runtimes_path, params: { runtime: { name: "Odd", type: "page", max_concurrent: 1, fields: { page: { config: "{not json" } } } }
      assert_response :unprocessable_entity
      assert_select "[role=alert]", text: /Config must be valid JSON/
      assert_select "input[name='runtime[name]'][value=Odd]"
      assert_select "textarea[name='runtime[fields][page][config]']", text: "{not json"

      post harbor.runtimes_path, params: { runtime: { name: "List", type: "page", max_concurrent: 1, fields: { page: { config: "[1]" } } } }
      assert_select "[role=alert]", text: /Config must be a JSON object/

      post harbor.runtimes_path, params: { runtime: { name: "Orca", type: "orca", max_concurrent: 1 } }
      assert_select "[role=alert]", text: /Choose the repository to work in/
    end
  end

  test "a backend that isn't offered is left off the new runtime form, and its runtimes are still edited" do
    PageBackend.offered = false
    get harbor.new_runtime_path
    assert_select "[data-runtime-choice=page]", count: 0
    assert_no_difference("Harbor::Runtime.count") do
      post harbor.runtimes_path, params: { runtime: { name: "Sneaked", type: "page", max_concurrent: 1 } }
    end
    assert_select "[role=alert]", text: /Choose what kind of runtime this is/

    get harbor.edit_runtime_path(@cloud)
    assert_select "[data-runtime-choice=page]"
    patch harbor.runtime_path(@cloud), params: { runtime: { name: "Cloud two", type: "page", max_concurrent: 4, enabled: "1",
                                                           fields: { page: { host: "two.example", config: '{"a": 1}' } } } }
    assert_redirected_to harbor.runtimes_path
    assert_equal [ "Cloud two", 4, "two.example", { "a" => 1 }, "cloud" ], @cloud.reload.then { |r| [ r.name, r.max_concurrent, r.host, r.config, r.key ] }
  ensure
    PageBackend.offered = true
  end

  test "a runtime's own page holds its settings, its health and its removal" do
    with_orca do
      orca = Harbor::Runtime.create!(name: "Droplet", backend: "orca", max_concurrent: 2,
                                     config: { "provider" => "digitalocean", "host" => "ssh:gone", "host_name" => "old-droplet", "project" => "github:acme/app" })
      get harbor.edit_runtime_path(orca)
      assert_response :success
      assert_select "h1", "Droplet"
      assert_select "[data-runtime-health]", text: /Taking new work|Not taking new work/
      assert_select "form[action=?]", harbor.check_runtime_path(orca)
      assert_select "input[name='runtime[type]']", count: 2, message: "only its own backend's kinds: a runtime doesn't change backend"
      assert_select "input[name='runtime[type]'][value='orca:remote'][checked]"
      assert_select "select[name='runtime[fields][orca:remote][host]'] option[selected][value='ssh:gone']", text: "ssh:gone (not in Orca now)"
      assert_select "form[action=?] input[name=_method][value=delete]", harbor.runtime_path(orca)

      patch harbor.runtime_path(orca), params: { runtime: { name: "Droplet", type: "orca", max_concurrent: 5, enabled: "0", fields: { orca: { repo: "id:r-1" } } } }
      assert_redirected_to harbor.runtimes_path
      assert_equal [ 5, false, { "repo" => "id:r-1" }, "droplet" ], orca.reload.then { |r| [ r.max_concurrent, r.enabled, r.config, r.key ] }
      assert_equal 1, @changes

      patch harbor.runtime_path(orca), params: { runtime: { name: "", type: "orca", max_concurrent: 5, fields: { orca: { repo: "id:r-1" } } } }
      assert_response :unprocessable_entity
      assert_select "[role=alert]", text: /Name can't be blank/
      assert_select "h1", "Droplet"
    end
    get harbor.edit_runtime_path(@cloud)
    assert_select "input[name=_method][value=delete]", count: 0, message: "a runtime in a workspace offers no Remove"
    assert_select "p", text: "Check the cable."
  end

  test "only a runtime nothing depends on can be removed" do
    spare = Harbor::Runtime.create!(key: "spare", name: "Spare", backend: "page")

    delete harbor.runtime_path(@cloud)
    assert_redirected_to harbor.edit_runtime_path(@cloud)
    assert_match "Cloud can't be removed", flash[:alert]
    assert Harbor::Runtime.exists?(@cloud.id)

    used = Harbor::Runtime.create!(key: "used", name: "Used", backend: "page")
    Harbor::Run.create!(skill: "writer.fix", status: "ok", runtime_id: used.id)
    delete harbor.runtime_path(used)
    assert_match "Used can't be removed", flash[:alert]

    delete harbor.runtime_path(spare)
    assert_equal "Spare removed.", flash[:notice]
    assert_not Harbor::Runtime.exists?(spare.id)
  end

  test "a health check records its result either way, and goes back to where it was asked" do
    PageBackend.healthy = false
    post harbor.check_runtime_path(@cloud)
    assert_redirected_to harbor.runtimes_path
    assert_match "Cloud failed its health check: RuntimeError: no answer", flash[:alert]
    assert_match "unhealthy", @cloud.reload.unavailable_reason
    PageBackend.healthy = true
    post harbor.check_runtime_path(@cloud), params: { from: "edit" }
    assert_redirected_to harbor.edit_runtime_path(@cloud)
    assert_equal "Cloud is healthy.", flash[:notice]
    assert_nil @cloud.reload.unavailable_reason
  end

  test "the workspaces page lists each workspace's runtimes in order, with who uses it" do
    Harbor::Agent.create!(key: "writer", workspace_profile: @workspace)
    @laptop.update!(enabled: false)
    get harbor.workspace_profiles_path
    assert_response :success
    assert_select "[data-workspace=default]" do
      assert_select "li", count: 2
      assert_select "li:first-child", text: /First\s*Cloud\s*0\/3 busy/
      assert_select "li:last-child", text: /Then 1\s*Laptop.*disabled/mii
      assert_select "p", text: /Agents: writer · key default/
    end
    assert_select "[data-harbor-nav] a[aria-current=page]", text: "Workspaces"
  end

  test "a workspace is created, reordered and deleted" do
    get harbor.new_workspace_profile_path
    assert_response :success
    assert_select "form[data-controller='harbor--nested-fields'] template"
    assert_select "select[name$='[runtime_id]'] option", text: "Laptop"

    post harbor.workspace_profiles_path, params: { workspace_profile: { name: "Overflow", description: "Laptop only",
      workspace_profile_runtimes_attributes: { "0" => { runtime_id: @laptop.id, position: 0 } } } }
    assert_redirected_to harbor.workspace_profiles_path
    overflow = Harbor::WorkspaceProfile.find_by!(key: "overflow")
    assert_equal [ @laptop ], overflow.ordered_runtimes

    post harbor.workspace_profiles_path, params: { workspace_profile: { name: "Empty" } }
    assert_response :unprocessable_entity
    assert_select "[role=alert]", text: /Add at least one runtime/

    get harbor.edit_workspace_profile_path(@workspace)
    assert_select "input[name='workspace_profile[key]'][readonly]"
    rows = @workspace.workspace_profile_runtimes.index_by(&:runtime_id)
    patch harbor.workspace_profile_path(@workspace), params: { workspace_profile: { workspace_profile_runtimes_attributes: {
      "0" => { id: rows[@cloud.id].id, runtime_id: @cloud.id, position: 1 },
      "1" => { id: rows[@laptop.id].id, runtime_id: @laptop.id, position: 0 } } } }
    assert_redirected_to harbor.workspace_profiles_path
    assert_equal [ @laptop, @cloud ], @workspace.reload.ordered_runtimes
    assert_equal 1, @changes

    delete harbor.workspace_profile_path(overflow)
    assert_equal "Workspace deleted.", flash[:notice]
    assert_not Harbor::WorkspaceProfile.exists?(overflow.id)
  end

  test "both pages can be switched off" do
    Harbor::Setting.set!(:page_runtimes, "false")
    get harbor.runtimes_path
    assert_response :not_found
    get harbor.workspace_profiles_path
    assert_response :success
    assert_select "[data-harbor-nav] a", text: "Runtimes", count: 0
  end
end
