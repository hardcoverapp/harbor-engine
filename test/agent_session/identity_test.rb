require "test_helper"

# What a session is given for the account its agent acts as (Harbor::Identity):
# the token from the variable the identity names, and the git author. The
# token is read when the runner asks and is kept nowhere.
class HarborAgentSessionIdentityTest < ActionDispatch::IntegrationTest
  include HarborAgentSessions

  Environment = Harbor::AgentSession::Environment
  VARIABLE = "HARBOR_TEST_PAT_RELEASE_BOT".freeze
  OTHER = "HARBOR_TEST_PAT_REVIEW_BOT".freeze
  TOKEN = "ghp_s3cr3tR3l3as3B0tT0k3n0123456789abcd".freeze
  GITHUB = { "GH_TOKEN" => TOKEN, "GITHUB_TOKEN" => TOKEN,
             "GIT_AUTHOR_NAME" => "release-bot", "GIT_AUTHOR_EMAIL" => "release-bot@users.noreply.github.com",
             "GIT_COMMITTER_NAME" => "release-bot", "GIT_COMMITTER_EMAIL" => "release-bot@users.noreply.github.com" }.freeze

  setup do
    Harbor::Identity.delete_all
    Harbor::Automations.reset!
    @env = [ VARIABLE, OTHER ].index_with { |name| ENV[name] }
    ENV[VARIABLE] = TOKEN
    ENV.delete(OTHER)
    @bot = Harbor::Identity.create!(name: "Release bot", login: "release-bot", token_env: VARIABLE)
    @agent.update!(identity: @bot)
  end

  teardown do
    @env.each { |name, value| value.nil? ? ENV.delete(name) : ENV[name] = value }
    Harbor::Automations.reset!
    clear_enqueued_jobs
  end

  def fetch_env(run)
    post "/harbor/runner/runs/#{run.id}/bundle/env", headers: runner_headers(run)
    response.body
  end

  # Everything written to the app's log while the block runs, SQL included.
  def logged
    io = StringIO.new
    extra = ActiveSupport::Logger.new(io)
    Rails.logger.broadcast_to(extra)
    yield
    io.string
  ensure
    Rails.logger.stop_broadcasting_to(extra)
  end

  test "an agent with an identity has its session given the account's token and git author" do
    run = start_session
    assert run.running?
    assert_equal GITHUB.map { |name, value| "export #{name}='#{value}'\n" }.join, fetch_env(run)
    assert_response :success
    assert_equal GITHUB, Environment.for(run, "anthropic")
    assert_match "[harbor] acting as Release bot (@release-bot), with the token in #{VARIABLE}", live_log(run)
  end

  test "an agent with no identity acts as nobody: its session is given nothing, as before" do
    @agent.update!(identity: nil)
    run = start_session
    assert run.running?
    assert_equal "", fetch_env(run)
    assert_equal({}, Environment.for(run, "anthropic"))
    assert_no_match(/acting as/, live_log(run))
  end

  test "the token is in no column, event, log, command line or job: only in the file the runner fetches" do
    run = nil
    log = logged do
      run = Harbor::AgentSession.run!(agent: @agent, prompt: "Fix the test.", attributes: { skill: "writer.fix" })
      assert_match TOKEN, fetch_env(run)
      post_output run, ndjson({ "type" => "system", "subtype" => "init", "session_id" => "s-1" })
      post_result run, 0
    end
    run.reload
    assert run.finished?
    assert_match(/harbor_identities/, log, "the log was being read, SQL and all")
    assert_no_match(/s3cr3t/, log, "not in the app's log, its SQL included")
    assert_no_match(/s3cr3t/, run.attributes.to_json, "no column of the run")
    assert_no_match(/s3cr3t/, Harbor::RunEvent.where(run_id: run.id).to_json)
    assert_no_match(/s3cr3t/, live_log(run))
    assert_no_match(/s3cr3t/, File.read(File.join(@logs, run.raw_log_path))) if run.raw_log_path && File.exist?(File.join(@logs, run.raw_log_path))
    assert_no_match(/s3cr3t/, @orca.calls.to_json, "no command line")
    assert_no_match(/s3cr3t/, (enqueued_jobs + performed_jobs).inspect, "no job's arguments")
    assert_no_match(/s3cr3t/, [ @bot.reload.attributes, @agent.reload.attributes ].to_json)
  end

  test "an identity whose variable isn't set stops the session before anything is made, saying which variable" do
    ENV.delete(VARIABLE)
    run = Harbor::AgentSession.run!(agent: @agent, prompt: "Fix the test.", attributes: { skill: "writer.fix" })

    assert_equal "error", run.reload.status
    assert_equal "The agent session could not be started: the identity Release bot (@release-bot) has no token here: #{VARIABLE} isn't set",
                 run.error
    assert_empty @orca.calls.select { |call| call[1, 2] == %w[worktree create] }, "no worktree and no terminal were made"
    assert_empty @orca.terminal_commands
    assert_not Harbor::AgentSession.session?(run)
    assert_equal [ 0, 0 ], [ Harbor::Slots.busy(@agent), Harbor::Slots.busy(@runtime) ], "and its slots were given back"
  end

  test "a variable that is empty is no token either" do
    ENV[VARIABLE] = ""
    assert_equal "error", start_session.reload.status
  end

  test "a variable taken away while the session runs is refused when the runner asks, in the log and by name only" do
    run = start_session
    ENV.delete(VARIABLE)
    body = fetch_env(run)
    assert_response :unprocessable_entity
    assert_equal "the identity Release bot (@release-bot) has no token here: #{VARIABLE} isn't set", body
    assert_match "the session's environment was refused: the identity Release bot", live_log(run)
    assert_raises(Environment::Missing) { Environment.for(run, "anthropic") }
  end

  test "the host's hook has the last word: it adds, replaces and takes away" do
    asked = []
    Harbor.config.agent_session_env = lambda do |run, provider|
      asked << [ run.id, provider ]
      { "GH_TOKEN" => "the-hosts-own", "GIT_AUTHOR_NAME" => "Build Bot", "GITHUB_TOKEN" => nil, "CLAUDE_CODE_OAUTH_TOKEN" => "oauth-1" }
    end
    run = start_session

    assert_equal GITHUB.merge("GH_TOKEN" => "the-hosts-own", "GIT_AUTHOR_NAME" => "Build Bot", "CLAUDE_CODE_OAUTH_TOKEN" => "oauth-1").except("GITHUB_TOKEN"),
                 Environment.for(run, "anthropic")
    file = fetch_env(run)
    assert_match(/^unset ANTHROPIC_API_KEY$/, file)
    assert_match(/^export GH_TOKEN='the-hosts-own'$/, file)
    assert_no_match(/GITHUB_TOKEN|s3cr3t/, file, "what the host replaced and removed is gone")
    assert_match(/^export GIT_COMMITTER_NAME='release-bot'$/, file, "what it didn't touch is the identity's")
    assert_includes asked, [ run.id, "anthropic" ]
  end

  test "a hook that gets a name wrong is still refused, with the identity's token in no message" do
    Harbor.config.agent_session_env = ->(*) { { "BAD NAME" => "x" } }
    run = start_session
    body = fetch_env(run)
    assert_response :unprocessable_entity
    assert_no_match(/s3cr3t/, body + live_log(run))
  end

  test "a run that names an identity acts as that one, not its agent's; a name that is no identity's gets nothing" do
    ENV[OTHER] = "ghp_s3cr3tR3vi3w"
    Harbor::Identity.create!(name: "Reviewer", login: "review-bot", token_env: OTHER)

    named = start_session(run: new_run(acting_as: "review-bot"))
    assert_equal [ "ghp_s3cr3tR3vi3w", "review-bot" ], Environment.for(named, "anthropic").values_at("GH_TOKEN", "GIT_AUTHOR_NAME")
    assert_match "acting as Reviewer (@review-bot)", live_log(named)

    hosts = start_session(run: new_run(acting_as: "the-hosts-own-name"))
    assert hosts.running?
    assert_equal({}, Environment.for(hosts, "anthropic"))

    ENV.delete(OTHER)
    unset = start_session(run: new_run(acting_as: "review-bot"))
    assert_equal "error", unset.reload.status, "the one it names must have its token, though the agent's has"
    assert_match "#{OTHER} isn't set", unset.error
  end

  test "an agent automation runs as its agent's identity, or as the one it names" do
    ENV[OTHER] = "ghp_s3cr3tR3vi3w"
    Harbor::Identity.create!(name: "Reviewer", login: "review-bot", token_env: OTHER)
    own = Harbor::Automation.create!(key: "tidy", name: "Tidy", kind: "agent", agent_key: "writer", prompt: "Tidy.")
    named = Harbor::Automation.create!(key: "check", name: "Check", kind: "agent", agent_key: "writer", prompt: "Check.", run_as: "review-bot")
    assert_equal [ @bot, "review-bot" ], [ own.identity, named.identity.login ]

    runs = [ own, named ].map do |automation|
      run = Harbor::Automations::AgentRunJob.dispatch!(automation, trigger_source: "manual")
      perform_enqueued_jobs(only: Harbor::Automations::AgentRunJob)
      run.reload
    end
    assert_equal [ true, true ], runs.map(&:running?)
    assert_equal [ nil, "review-bot" ], runs.map(&:acting_as)
    assert_equal [ "release-bot", "review-bot" ], runs.map { |run| Environment.for(run, "anthropic")["GIT_AUTHOR_NAME"] }
    assert_equal [ TOKEN, "ghp_s3cr3tR3vi3w" ], runs.map { |run| Environment.for(run, "anthropic")["GH_TOKEN"] }
  end

  test "with no identities declared by the host an automation picks among Harbor's, or none; a host's own list is left as it was" do
    assert Harbor::Automations.own_identities?
    assert_equal [ [ "release-bot", "Release bot (@release-bot)" ] ], Harbor::Automations.run_as_choices.map { |choice| [ choice.key, choice.label ] }
    assert_empty Harbor::Automations.identities, "what the host declared is still only that"
    build = ->(run_as) { Harbor::Automation.new(key: "a-#{SecureRandom.hex(2)}", name: "A", kind: "agent", agent_key: "writer", prompt: "Go.", run_as:) }
    assert build.(nil).valid?
    assert build.("Release-Bot").valid?
    stranger = build.("somebody")
    assert_not stranger.valid?
    assert_equal [ "is not an identity (Agents, Identities)" ], stranger.errors[:run_as]

    Harbor::Automations.identity "badge-7", label: "Badge 7"
    assert_not Harbor::Automations.own_identities?
    assert_equal %w[badge-7], Harbor::Automations.run_as_choices.map(&:key)
    assert build.("badge-7").valid?
    assert_equal [ "is not an identity this site declared" ], build.("release-bot").tap(&:valid?).errors[:run_as]

    Harbor::Automations.reset!
    Harbor::Identity.delete_all
    assert_not Harbor::Automations.own_identities?
    assert build.("anything-at-all").valid?, "with no identities anywhere nothing is asked, as before"
  end
end
