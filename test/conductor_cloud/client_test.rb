require "test_helper"

# Harbor's client for Conductor's API: what it sends, and how it reads what
# comes back. Every request here goes to a stand-in.
class HarborConductorCloudClientTest < ActiveSupport::TestCase
  include SingletonStub

  Client = Harbor::ConductorCloud::Client

  setup do
    @api = FakeConductorCloud.new
    @agent = Harbor.config.conductor_cloud_user_agent
  end

  teardown { Harbor.config.conductor_cloud_user_agent = @agent }

  def client(**options) = Client.new(api_key: "secret-key", base_url: "https://conductor.test/", transport: @api, **options)

  test "each call is the request Conductor's API documents" do
    api = client
    api.create_workspace(repository_url: "https://github.com/acme/app", branch: "main", name: "harbor-run-7", agent: "codex",
                         model: "gpt-5.5", effort: "high", message: "Fix it.", env: { "GH_TOKEN" => "t" })
    api.create_workspace(repository_url: "https://github.com/acme/app", name: "harbor-run-8", model: "opus-5-5-1m", message: "Go.")
    api.workspaces(name: "harbor-run-7", repo: "https://github.com/acme/app", offset: 100)
    api.create_session(workspace_id: "ws-1", model: "opus-5-5-1m", effort: "high")
    api.rename_workspace("ws-1", name: "renamed")
    api.sections(offset: 100)
    api.create_section(name: "Reviews")
    api.move_workspace("ws-1", section_id: "sec-1")
    api.session_status("sess-1")
    api.messages("sess-1", after: "m-4")
    api.send_message("sess-1", "And this.")
    api.cancel_session("sess-1")
    api.workspace_status("ws-1")
    api.archive_workspace("ws-1")

    assert_equal [ "POST /v0/workspaces", "POST /v0/workspaces", "GET /v0/workspaces", "POST /v0/sessions", "POST /v0/workspaces/ws-1/rename",
                   "GET /v0/sections", "POST /v0/sections", "PUT /v0/workspaces/ws-1/section", "GET /v0/sessions/sess-1/status",
                   "GET /v0/sessions/sess-1/messages", "POST /v0/sessions/sess-1/messages", "POST /v0/sessions/sess-1/cancel",
                   "GET /v0/workspaces/ws-1/status", "POST /v0/workspaces/ws-1/archive" ], @api.sent
    params = @api.requests.map(&:params)
    assert_equal({ "repositoryUrl" => "https://github.com/acme/app", "branch" => "main", "name" => "harbor-run-7", "agent" => "codex",
                   "model" => "gpt-5.5", "effort" => "high", "message" => "Fix it.", "env" => { "GH_TOKEN" => "t" } }, params[0])
    assert_equal({ "repositoryUrl" => "https://github.com/acme/app", "name" => "harbor-run-8", "agent" => "claude", "model" => "opus-5-5-1m",
                   "message" => "Go.", "env" => {} }, params[1], "no branch: the repository's default; claude unless told")
    assert_equal({ "name" => "harbor-run-7", "repo" => "https://github.com/acme/app", "offset" => "100", "limit" => "100" }, params[2])
    assert_equal({ "workspaceId" => "ws-1", "agent" => "claude", "model" => "opus-5-5-1m", "effort" => "high" }, params[3])
    assert_equal({ "name" => "renamed" }, params[4])
    assert_equal({ "sectionId" => "sec-1" }, params[7])
    assert_equal({ "after" => "m-4", "limit" => "100" }, params[9])
    assert_equal({ "message" => "And this." }, params[10])
  end

  test "every request carries the key and a user agent that names Harbor, or the one the host set" do
    client.sections
    headers = @api.requests.last.headers
    assert_equal "Bearer secret-key", headers["authorization"]
    assert_equal "harbor-engine/#{Harbor::VERSION}", headers["user-agent"]

    Harbor.config.conductor_cloud_user_agent = "acme-factory (factory.example.com)"
    client.sections
    assert_equal "acme-factory (factory.example.com)", @api.requests.last.headers["user-agent"]
    client(user_agent: "given").sections
    assert_equal "given", @api.requests.last.headers["user-agent"]
  end

  test "with no key nothing is sent, and the error names the variable" do
    error = assert_raises(Client::MissingKey) { Client.new(api_key: nil, key_name: "ACME_CONDUCTOR_KEY", transport: @api).sections }
    assert_equal "ACME_CONDUCTOR_KEY not set", error.message
    assert_empty @api.requests
    assert_not Client.new(api_key: "", transport: @api).configured?
    assert_kind_of Client::Error, error
  end

  test "a 5xx, an unreadable 5xx and a network failure are Unavailable; a 404 is NotFound; anything else is an Error" do
    answer = ->(code, body) { Client.new(api_key: "k", transport: ->(_) { [ code, body ] }) }

    error = assert_raises(Client::Unavailable) { answer.(500, '{"userMessage":"Postgres pool checkout queue is full"}').session_status("s-1") }
    assert_equal "Conductor GET /v0/sessions/s-1/status → 500: Postgres pool checkout queue is full", error.message
    error = assert_raises(Client::Unavailable) { answer.(502, "<html>bad gateway</html>").session_status("s-1") }
    assert_match "returned unparseable JSON (502)", error.message

    [ Net::ReadTimeout, Net::OpenTimeout, Errno::ECONNRESET, Errno::ECONNREFUSED, SocketError, EOFError ].each do |failure|
      error = assert_raises(Client::Unavailable) { Client.new(api_key: "k", transport: ->(_) { raise failure }).session_status("s-1") }
      assert_match "Conductor GET /v0/sessions/s-1/status unreachable: #{failure}", error.message
    end

    error = assert_raises(Client::NotFound) { answer.(404, '{"userMessage":"not found"}').workspace_status("ws-9") }
    assert_match "→ 404: not found", error.message
    assert_not_kind_of Client::Unavailable, error

    error = assert_raises(Client::Error) { answer.(401, '{"userMessage":"bad key"}').sections }
    assert_equal [ Client::Error, "Conductor GET /v0/sections → 401: bad key" ], [ error.class, error.message ]
    error = assert_raises(Client::Error) { answer.(200, "not json").sections }
    assert_equal Client::Error, error.class
    assert_equal({}, answer.(204, "").archive_workspace("ws-1"))
  end

  test "with no transport of its own it makes a real HTTPS request, which the tests never let out" do
    seen = []
    http = Object.new
    http.define_singleton_method(:request) do |request|
      seen << request
      Net::HTTPOK.new("1.1", "200", "OK").tap { |response| response.define_singleton_method(:body) { '{"data":[]}' } }
    end
    started = nil
    with_stub(Net::HTTP, :start, ->(host, port, **options, &block) { started = [ host, port, options[:use_ssl] ]; block.call(http) }) do
      assert_equal({ "data" => [] }, Client.new(api_key: "k").sections(limit: 1))
    end
    assert_equal [ "api.conductor.build", 443, true ], started
    assert_equal "/v0/sections?offset=0&limit=1", seen.first.uri.request_uri
  end

  test "Conductor's model ids: its own, a model's with the 1M variant where there is one, a bare family, and a host's additions" do
    models = Harbor::ConductorCloud::Models
    assert_equal "opus-5-5-1m", models.id_for("claude-opus-5-5")
    assert_equal "opus-5-5-1m", models.id_for("opus-5-5-1m")
    assert_equal "opus-5-5-1m", models.id_for("claude-opus-5-5[1m]")
    assert_equal "opus-5-5-1m", models.id_for("claude-opus-5.5")
    assert_equal "haiku-4-5", models.id_for("claude-haiku-4-5-20251001"), "a dated id; no 1M variant offered"
    assert_equal "sonnet-4-6-1m", models.id_for("claude-sonnet-4-6")
    assert_equal "fable-5-2", models.id_for("claude-fable-5-2")
    assert_equal "gpt-5.5", models.id_for("gpt-5.5")
    assert_equal "opus-5-5-1m", models.id_for("opus"), "a bare family is the first of that family"
    assert_nil models.id_for("claude-opus-4-5"), "Conductor has no Opus 4.5"
    assert_nil models.id_for("gemini-3-pro")
    assert_nil models.id_for("")
    assert_nil models.id_for(nil)

    assert_nil models.id_for("claude-opus-6")
    Harbor.config.conductor_cloud_models = %w[opus-6-1m]
    assert_equal "opus-6-1m", models.id_for("claude-opus-6")
    assert_equal "opus-6-1m", models.id_for("opus"), "a host's ids come first"
    assert_equal "high", models.effort_for("high")
    assert_nil models.effort_for("enormous")
  ensure
    Harbor.config.conductor_cloud_models = []
  end
end
