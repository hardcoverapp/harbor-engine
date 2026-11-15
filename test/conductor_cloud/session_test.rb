require "test_helper"

# An agent session on a Conductor Cloud runtime: started, followed by asking,
# recorded, finished, stopped, timed out, picked up after a restart and
# cleaned up. Conductor's API is a stand-in throughout; none of this has been
# run against the real service.
class HarborConductorCloudSessionTest < ActionDispatch::IntegrationTest
  include HarborAgentSessions
  include HarborConductorCloud
  include SingletonStub

  PollJob = Harbor::AgentSession::PollJob
  WatchJob = Harbor::AgentSession::WatchJob

  INIT = { "type" => "system", "subtype" => "init", "session_id" => "c-1", "model" => "claude-sonnet-5-5" }.freeze
  LOOKING = { "type" => "assistant", "message" => { "content" => [ { "type" => "text", "text" => "Looking." } ] } }.freeze
  TESTS = { "type" => "assistant", "message" => { "content" => [ { "type" => "tool_use", "id" => "t-1", "name" => "Bash", "input" => { "command" => "bin/test" } } ] } }.freeze
  DONE = { "type" => "result", "subtype" => "success", "is_error" => false, "session_id" => "c-1", "result" => "All fixed.", "num_turns" => 3,
           "total_cost_usd" => 0.42, "duration_ms" => 61_000,
           "usage" => { "input_tokens" => 10, "output_tokens" => 20, "cache_read_input_tokens" => 300, "cache_creation_input_tokens" => 40 } }.freeze

  setup do
    @cloud = cloud_runtime
    # A Conductor Cloud session needs no runner address: nothing posts back.
    Harbor::Setting.where(key: "runner_url").delete_all
  end

  def start_cloud(run: new_run, prompt: "Fix the test.", **options)
    Harbor::AgentSession.start!(run:, agent: @agent, prompt:, runtime: @cloud, choice: @choice, **options)
  end

  # One look at the session, as the job following it makes.
  def poll(run) = PollJob.perform_now(run.id, run.reload.runner_state["poll_chain"])

  def progress(run) = run.reload.runner_state["conductor"]

  def created = @conductor.last("POST /v0/workspaces").params

  # --- starting ---

  test "starting a session makes a workspace whose first message is what the agent is told and its prompt" do
    Harbor.config.agent_session_env = ->(_run, provider) { { "GH_TOKEN" => "gh-secret", "CLAUDE_CODE_OAUTH_TOKEN" => "#{provider}-secret" } }
    run = travel_to(Time.zone.parse("2026-11-15 10:00:00")) { start_cloud }

    assert run.running?
    assert_equal [ "claude-sonnet-5-5", "medium", "conductor_cloud", "Cloud", @cloud.id ],
                 [ run.model, run.effort, run.executor, run.runner_name, run.runtime_id ]
    assert_equal "claude <prompt…> --model sonnet-5-5-1m --effort medium (Conductor Cloud)", run.command
    assert_equal({ "workspace_id" => "ws-1", "session_id" => "sess-1", "name" => "harbor-run-#{run.id}", "deep_link" => "conductor://workspace/ws-1" },
                 run.runner_state["session"])
    assert_equal [ "setup", nil ], progress(run).values_at("phase", "last_message_id")
    assert Harbor::AgentSession.session?(run)
    assert Harbor::AgentSession.polled?(run)

    assert_equal [ "POST /v0/workspaces" ], @conductor.sent
    assert_equal({ "repositoryUrl" => "https://github.com/acme/app", "name" => "harbor-run-#{run.id}", "agent" => "claude", "model" => "sonnet-5-5-1m",
                   "effort" => "medium", "message" => "You write.\n\n#{Harbor::AgentSession::UNATTENDED}\n\n---\n\nFix the test.",
                   "env" => { "GH_TOKEN" => "gh-secret", "CLAUDE_CODE_OAUTH_TOKEN" => "anthropic-secret" } }, created)
    assert_no_match(/gh-secret|anthropic-secret|test-conductor-key/, run.reload.attributes.to_json + live_log(run), "no secret is kept with the run or logged")
    assert_match "[conductor] workspace harbor-run-#{run.id} · claude sonnet-5-5-1m · conductor://workspace/ws-1", live_log(run)
    assert_match "[conductor] not applied here (Conductor starts the agent with its own settings): allowed_tools", live_log(run)
    assert_empty @orca.calls, "no terminal, and no runner script"

    assert_enqueued_with(job: PollJob, args: [ run.id, 1 ])
    assert_enqueued_with(job: WatchJob, args: [ run.id, "timeout" ], at: Time.zone.parse("2026-11-15 10:30:00"))
  end

  test "the workspace starts from the runtime's branch, or the one the session names; a slash command is read from its ref" do
    @cloud.update!(config: @cloud.config.merge("branch" => "develop"))
    run = start_cloud(prompt: nil, slash_command: "/tidy:shelf 12 --fast", command_ref: "origin/main")

    assert_equal "develop", created["branch"]
    assert_equal "claude /tidy:shelf 12 --fast --model sonnet-5-5-1m --effort medium (Conductor Cloud)", run.command
    system, task = created["message"].split("\n\n---\n\n")
    assert_equal "You write.\n\n#{Harbor::AgentSession::UNATTENDED}", system
    assert_equal "Read the file `.claude/commands/tidy/shelf.md` as it is at the git ref `origin/main` " \
                 "(`git show origin/main:.claude/commands/tidy/shelf.md`), not the copy checked out, and carry out its instructions as your task. " \
                 "Ignore any YAML frontmatter at its top. Where it says $ARGUMENTS use: 12 --fast. Its positional arguments are: $1 = 12, $2 = --fast.", task
    assert_match "[conductor] workspace harbor-run-#{run.id} on develop", live_log(run)

    start_cloud(prompt: nil, slash_command: "/tidy", base: "feature/shelves")
    assert_equal "feature/shelves", created["branch"]
    assert_match "Read the file `.claude/commands/tidy.md` in this repository, and carry out its instructions as your task. " \
                 "Ignore any YAML frontmatter at its top. It was given no arguments.", created["message"]
  end

  test "an OpenAI model runs as codex, and Conductor's wrapped codex events are read as codex prints them" do
    gpt = Harbor::ModelAlias.create!(name: "Other", model_choices_attributes: [ { model_provider: @openai, model: "gpt-5.5", effort: "high", position: 0 } ])
    run = Harbor::AgentSession.start!(run: new_run, agent: @agent, prompt: "Read it.", runtime: @cloud, choice: gpt.model_choices.first)
    assert_equal [ "codex", "gpt-5.5", "high" ], created.values_at("agent", "model", "effort")
    assert_equal "codex <prompt…> --model gpt-5.5 --effort high (Conductor Cloud)", run.reload.command

    @conductor.say({ "event" => { "type" => "thread.started", "thread_id" => "th-1" }, "thread_id" => "th-1" },
                   { "event" => { "type" => "item.completed", "item" => { "type" => "agentMessage", "text" => "Read. Nothing to do." } } },
                   { "event" => { "type" => "turn.completed", "usage" => { "input_tokens" => 100, "cached_input_tokens" => 40, "output_tokens" => 7 } } })
    poll(run)
    run.reload
    assert run.ok?
    assert_equal [ "th-1", 60, 7, 40, "Read. Nothing to do." ],
                 [ run.session_id, run.input_tokens, run.output_tokens, run.cache_read_tokens, run.output["text"] ]
    assert_match "[init] Codex session th-1", live_log(run)
  end

  test "a workspace that can't be made finishes the run as an error and gives its slots back" do
    @agent.update!(workspace_profile: Harbor::WorkspaceProfile.create!(name: "Cloud", workspace_profile_runtimes_attributes: [ { runtime: @cloud, position: 0 } ]))
    @conductor.refuse("POST /v0/workspaces", code: 401, message: "bad key")
    run = Harbor::AgentSession.run!(agent: @agent, prompt: "Fix the test.", attributes: { skill: "writer.fix" })

    assert run.reload.error?
    assert_equal "The agent session could not be started: Conductor POST /v0/workspaces → 401: bad key", run.error
    assert_equal 0, @cloud.busy
    assert_no_enqueued_jobs only: PollJob
  end

  test "a workspace name Conductor says is taken is tried once more with a suffix" do
    @conductor.refuse("POST /v0/workspaces", code: 409, message: "a workspace with that name already exists")
    run = start_cloud
    assert run.running?
    assert_equal 2, @conductor.sent.count("POST /v0/workspaces")
    assert_match(/\Aharbor-run-#{run.id}-\h{4}\z/, created["name"])
    assert_equal created["name"], run.runner_state.dig("session", "name")
  end

  test "an earlier session can't be continued here, so the session starts from its prompt and says so" do
    run = start_cloud(resume_session_id: "abc-1")
    assert_nil run.runner_state["resume_session_id"]
    assert_nil run.input.dig("agent_session", "command", "resume_session_id")
    assert_match "[harbor] an earlier session can't be continued on Cloud: this one starts from its prompt", live_log(run)
  end

  test "a backend that takes no agent sessions is refused like one that can't start commands" do
    quiet = Class.new(Harbor::Runtimes::Backends::ConductorCloud) { def self.agent_sessions? = false }
    self.class.const_set(:QuietBackend, quiet) unless self.class.const_defined?(:QuietBackend)
    Harbor::Runtimes.register "quiet", "HarborConductorCloudSessionTest::QuietBackend"
    runtime = cloud_runtime(key: "quiet", name: "Quiet", backend: "quiet")
    run = Harbor::AgentSession.start!(run: new_run, agent: @agent, prompt: "Fix it.", runtime:, choice: @choice)

    assert run.reload.error?
    assert_equal "The agent session could not be started: Quiet can't run agent sessions: its backend (quiet) doesn't start commands.", run.error
    assert_empty @conductor.requests
  ensure
    Harbor::Runtimes.unregister "quiet"
  end

  # --- setup ---

  test "while the workspace sets up only its status is asked, said once, and the run's own clock has not started" do
    @conductor.workspace = "initializing"
    @conductor.lifecycle = "setting_up"
    start = Time.zone.parse("2026-11-15 10:00:00")
    run = travel_to(start) { start_cloud(timeout: 20.minutes, idle_timeout: 5.minutes) }
    clear_enqueued_jobs

    travel_to(start + 6.minutes) do
      2.times { poll(run) }
      assert run.reload.running?
      assert_equal [ "GET /v0/workspaces/ws-1/status" ] * 2, @conductor.sent.last(2)
      assert_equal 1, live_log(run).scan("[conductor] waiting for harbor-run-#{run.id} to finish setting up (setting_up)").size
      assert_equal start + 26.minutes, Time.zone.parse(run.runner_state["timeout_at"])
      assert_enqueued_with(job: PollJob, args: [ run.id, 1 ], at: 10.seconds.from_now)
      WatchJob.perform_now(run.id, "idle")
      assert run.reload.running?, "it has not been quiet: it has not started"
    end

    travel_to(start + 21.minutes) do
      poll(run)
      WatchJob.perform_now(run.id, "timeout")
      assert run.reload.running?, "setup is not counted against the run's timeout"
    end

    @conductor.workspace = "ready"
    travel_to(start + 22.minutes) do
      poll(run)
      assert_equal "command", progress(run)["phase"]
      assert_match "[conductor] harbor-run-#{run.id} is ready; following its session", live_log(run)
      assert_equal start + 42.minutes, Time.zone.parse(run.reload.runner_state["timeout_at"])
      assert_equal [ "GET /v0/workspaces/ws-1/status", "GET /v0/sessions/sess-1/messages", "GET /v0/sessions/sess-1/status" ], @conductor.sent.last(3)
    end
  end

  test "a workspace that fails its setup, is archived, or takes too long finishes the run as an error" do
    @conductor.workspace = "initializing"
    failed = start_cloud
    @conductor.workspace_error = "setup script exited 1"
    poll(failed)
    assert_equal [ "error", "The Conductor Cloud workspace harbor-run-#{failed.id} could not be set up: setup script exited 1" ],
                 failed.reload.then { |run| [ run.status, run.error ] }
    assert_includes @conductor.sent, "POST /v0/workspaces/ws-1/archive"

    @conductor.workspace_error = nil
    @conductor.workspace = "archived"
    gone = start_cloud
    poll(gone)
    assert_equal "The Conductor Cloud workspace harbor-run-#{gone.id} is archived.", gone.reload.error

    @conductor.workspace = "initializing"
    slow = start_cloud(timeout: nil)
    travel(29.minutes) { poll(slow) }
    assert slow.reload.running?
    travel(31.minutes) { poll(slow) }
    assert_equal "The Conductor Cloud workspace harbor-run-#{slow.id} wasn't ready after 30 minutes of setup.", slow.reload.error

    Harbor::Setting.set!(:conductor_cloud_setup_minutes, 5)
    quick = start_cloud(timeout: nil)
    travel(6.minutes) { poll(quick) }
    assert_match "wasn't ready after 5 minutes of setup", quick.reload.error
  end

  # --- following and recording ---

  test "a site with no code of its own runs an agent there: the transcript becomes the log, events, cost, tokens and result" do
    @agent.update!(workspace_profile: Harbor::WorkspaceProfile.create!(name: "Cloud", workspace_profile_runtimes_attributes: [ { runtime: @cloud, position: 0 } ]))
    finished = []
    Harbor.config.agent_session_finished = ->(run) { finished << [ run.id, run.status ] }
    run = Harbor::AgentSession.run!(agent: @agent, prompt: "Fix the test.", attributes: { skill: "writer.fix", task_type: "fix" })
    assert run.running?
    assert_equal 1, @cloud.busy

    @conductor.prompted
    @conductor.say(INIT, LOOKING, TESTS)
    poll(run)
    run.reload
    assert run.running?
    assert_equal "c-1", run.session_id
    assert_equal ndjson(INIT, LOOKING, TESTS), raw_stream(run)
    assert_equal [ "[init] session c-1 · model claude-sonnet-5-5", "Looking.", "⏺ Bash(bin/test)" ], live_log(run).lines.map(&:chomp).last(3)
    assert_equal [ %w[system init], %w[assistant text], %w[assistant tool_use] ], run.run_events.order(:seq).pluck(:event_type, :subtype)
    assert_equal [ "m-4", true ], progress(run).values_at("last_message_id", "working")
    assert_enqueued_with(job: PollJob, args: [ run.id, 1 ])

    @conductor.say(DONE)
    clear_enqueued_jobs
    poll(run)
    run.reload
    assert run.ok?
    assert_equal({ "after" => "m-4", "limit" => "100" }, @conductor.last("GET /v0/sessions/sess-1/messages").params, "only what is new is read")
    assert_equal [ 0.42, 61_000, 10, 20, 300, 40, "c-1", "claude-sonnet-5-5", nil ],
                 [ run.cost_usd_actual.to_f, run.duration_ms, run.input_tokens, run.output_tokens, run.cache_read_tokens, run.cache_creation_tokens,
                   run.session_id, run.model, run.error_class ]
    assert_equal({ "exit_code" => 0, "text" => "All fixed." }, run.output)
    assert_equal ndjson(INIT, LOOKING, TESTS, DONE), raw_stream(run)
    assert_equal %w[result success], run.run_events.order(:seq).last.then { |event| [ event.event_type, event.subtype ] }
    assert_match "[result] success · 61s · $0.42", live_log(run)
    assert_match(/<!-- run finished at .*: ok -->/, live_log(run))

    assert_equal [ "POST /v0/sessions/sess-1/cancel", "POST /v0/workspaces/ws-1/archive" ], @conductor.sent.last(2), "the workspace is put away"
    assert_equal 0, @cloud.busy, "and its slots are given back"
    assert_equal [ [ run.id, "ok" ] ], finished
    assert_no_enqueued_jobs only: PollJob
    requests = @conductor.requests.size
    poll(run)
    assert_equal requests, @conductor.requests.size, "a finished run is not asked about"
  end

  test "an agent automation placed on a Conductor Cloud runtime runs through Harbor's own job, unchanged" do
    @agent.update!(workspace_profile: Harbor::WorkspaceProfile.create!(name: "Cloud", workspace_profile_runtimes_attributes: [ { runtime: @cloud, position: 0 } ]))
    automation = Harbor::Automation.create!(key: "tidy", name: "Tidy", kind: "agent", agent_key: "writer", prompt: "Tidy the {{thing}}.",
                                            trigger_kind: "manual", timeout_ms: 600_000)
    run = Harbor::Automations::AgentRunJob.dispatch!(automation, trigger_source: "manual", context: { "thing" => "shelf" })
    perform_enqueued_jobs(only: Harbor::Automations::AgentRunJob)

    assert run.reload.running?
    assert_equal [ "conductor_cloud", 600 ], [ run.executor, run.runner_state["timeout"] ]
    assert_match(/\n\n---\n\nTidy the shelf\.\z/, created["message"])
    @conductor.say(INIT, DONE)
    poll(run)
    assert run.reload.ok?
  end

  test "a transcript longer than a page is read to its end in one look" do
    run = start_cloud
    @conductor.page_size = 2
    @conductor.say(INIT, LOOKING, TESTS, LOOKING, TESTS)
    poll(run)
    assert_equal 5, run.run_events.count
    assert_equal "m-5", progress(run)["last_message_id"]
    assert_equal [ nil, "m-2", "m-4" ], @conductor.requests.select { |request| request.path.end_with?("/messages") }.map { |request| request.params["after"] }
  end

  test "two looks at once record a message once" do
    run = start_cloud
    poll(run)
    @conductor.say(INIT, LOOKING)
    nested = false
    Harbor::ConductorCloud.transport = lambda do |request|
      # While one look has read the transcript and not yet recorded it, another makes a whole look.
      answer = @conductor.call(request)
      if request.uri.path.end_with?("/messages") && !nested
        nested = true
        poll(run)
      end
      answer
    end
    poll(run)

    assert_equal ndjson(INIT, LOOKING), raw_stream(run)
    assert_equal 2, run.run_events.count
    assert_equal 1, live_log(run).scan("Looking.").size
  end

  # --- how it ends ---

  test "a session that goes idle after working with no result is an error" do
    run = start_cloud
    @conductor.say(INIT)
    poll(run)
    assert run.reload.running?
    @conductor.session = "idle"
    poll(run)

    run.reload
    assert_equal [ "error", "The agent ended without a successful result.", 1 ], [ run.status, run.error, run.output["exit_code"] ]
    assert_includes @conductor.sent, "POST /v0/workspaces/ws-1/archive"
  end

  test "what the session wrote between the last look and going idle is read before it is finished" do
    run = start_cloud
    @conductor.say(INIT)
    poll(run)
    @conductor.session = "idle"
    # The result lands after this look has read the transcript and before it asks how the session is.
    Harbor::ConductorCloud.transport = lambda do |request|
      @conductor.say(DONE) if request.uri.path.end_with?("/status") && request.uri.path.include?("/sessions/") && @conductor.sent.count("GET /v0/sessions/sess-1/status") == 1
      @conductor.call(request)
    end
    poll(run)
    assert run.reload.ok?
    assert_equal "All fixed.", run.output["text"]
  end

  test "a result that isn't a success fails the run with what the agent said, and still records what it cost" do
    run = start_cloud
    @conductor.say(INIT, LOOKING, DONE.merge("subtype" => "error_max_turns", "is_error" => true, "result" => "Ran out of turns."))
    poll(run)

    run.reload
    assert_equal [ "error", "Ran out of turns.", "error_max_turns", 0.42 ], [ run.status, run.error, run.error_class, run.cost_usd_actual.to_f ]
    assert_match "[conductor] ERROR: Ran out of turns.", live_log(run)
  end

  test "a session Conductor reports as errored fails the run with its message" do
    run = start_cloud
    poll(run)
    @conductor.session = "error"
    @conductor.session_error = "the sandbox crashed"
    poll(run)
    assert_equal [ "error", "The Conductor Cloud session failed: the sandbox crashed" ], run.reload.then { |r| [ r.status, r.error ] }
  end

  test "a session that never starts working was never given its message" do
    @conductor.session = "idle"
    run = start_cloud(timeout: nil)
    poll(run)
    travel(14.minutes) { poll(run) }
    assert run.reload.running?
    travel(16.minutes) { poll(run) }
    assert_equal "The Conductor Cloud session never started working: its first message was not delivered.", run.reload.error
  end

  test "something Conductor refuses outright ends the run; it would not get better by asking again" do
    run = start_cloud
    poll(run)
    @conductor.refuse("GET /v0/sessions/sess-1/messages", code: 404, message: "session not found")
    poll(run)
    assert_equal [ "error", "Conductor refused: Conductor GET /v0/sessions/sess-1/messages → 404: session not found" ], run.reload.then { |r| [ r.status, r.error ] }
  end

  # --- Conductor's API being away ---

  test "Conductor's API being briefly unavailable is not a failure: the next look asks again from where it was" do
    run = start_cloud
    @conductor.say(INIT)
    poll(run)
    clear_enqueued_jobs

    @conductor.down = true
    freeze_time do
      3.times { poll(run) }
      assert run.reload.running?
      assert_equal 1, live_log(run).scan("→ 503: Service unavailable; still following the session").size, "said once"
      assert_equal "m-1", progress(run)["last_message_id"]
      assert_enqueued_with(job: PollJob, args: [ run.id, 1 ], at: 10.seconds.from_now)
      travel 90.seconds
      @conductor.down = false
      @conductor.say(LOOKING, DONE)
      poll(run)
    end

    run.reload
    assert run.ok?
    assert_match "[conductor] Conductor's API is answering again after 90s", live_log(run)
    assert_equal ndjson(INIT, LOOKING, DONE), raw_stream(run)
  end

  test "the key going missing from the environment is waited out too, and the run's timeout still bounds the wait" do
    run = start_cloud(timeout: 20.minutes)
    poll(run)
    ENV.delete("CONDUCTOR_API_KEY")
    poll(run)
    assert run.reload.running?
    assert_match "[conductor] CONDUCTOR_API_KEY not set; still following the session", live_log(run)

    travel(21.minutes) { WatchJob.perform_now(run.id, "timeout") }
    assert run.reload.timeout?
  end

  # --- stopping and timeouts ---

  test "Stop cancels the session, archives the workspace and finishes the run as canceled" do
    run = start_cloud
    @conductor.say(INIT)
    poll(run)
    assert Harbor::RunStop.possible?(run.reload)
    assert_equal "Stopped run ##{run.id}.", Harbor::RunStop.call(run, nil)

    run.reload
    assert run.canceled?
    assert_equal [ "POST /v0/sessions/sess-1/cancel", "POST /v0/sessions/sess-1/cancel", "POST /v0/workspaces/ws-1/archive" ], @conductor.sent.last(3)
    assert_equal "c-1", run.session_id
    requests = @conductor.requests.size
    poll(run)
    assert_equal requests, @conductor.requests.size
  end

  test "a session still running when its time is up is stopped as a timeout" do
    run = freeze_time { start_cloud(timeout: 20.minutes).tap { |started| poll(started) } }
    travel(19.minutes) { WatchJob.perform_now(run.id, "timeout") }
    assert run.reload.running?
    travel(21.minutes) { WatchJob.perform_now(run.id, "timeout") }

    run.reload
    assert run.timeout?
    assert_equal "Stopped: it had 20 minutes and was still running.", run.error
    assert_includes @conductor.sent, "POST /v0/sessions/sess-1/cancel"
    assert_includes @conductor.sent, "POST /v0/workspaces/ws-1/archive"
  end

  test "a session that writes nothing for its idle limit is stopped" do
    run = start_cloud(timeout: nil, idle_timeout: 5.minutes)
    @conductor.say(INIT)
    poll(run)
    travel(4.minutes) do
      poll(run)
      WatchJob.perform_now(run.id, "idle")
    end
    assert run.reload.running?
    travel(6.minutes) do
      poll(run)
      WatchJob.perform_now(run.id, "idle")
    end
    assert_equal [ "timeout", "Stopped: nothing was printed for 5 minutes." ], run.reload.then { |r| [ r.status, r.error ] }
  end

  test "a kept workspace is not archived" do
    run = start_cloud(keep_worktree: true)
    @conductor.say(INIT, DONE)
    poll(run)
    assert run.reload.ok?
    assert_not_includes @conductor.sent, "POST /v0/workspaces/ws-1/archive"
  end

  # --- restarts ---

  test "after a restart of the app the session is followed again from where reading stopped" do
    run = start_cloud
    @conductor.say(INIT)
    poll(run)
    clear_enqueued_jobs

    # The app was down; the session went on in the cloud.
    @conductor.say(LOOKING, DONE)
    Harbor::AgentSession.recover!
    assert_equal 2, run.reload.runner_state["poll_chain"]
    assert_enqueued_with(job: PollJob, args: [ run.id, 2 ])

    requests = @conductor.requests.size
    PollJob.perform_now(run.id, 1)
    assert_equal requests, @conductor.requests.size, "a look left over from before the restart stops"

    poll(run)
    run.reload
    assert run.ok?
    assert_equal "m-1", @conductor.last("GET /v0/sessions/sess-1/messages").params["after"]
    assert_equal ndjson(INIT, LOOKING, DONE), raw_stream(run)
    assert_equal 0.42, run.cost_usd_actual.to_f
    assert_equal 1, @conductor.sent.count("POST /v0/workspaces"), "nothing was started again"
  end

  test "a session that has gone quiet is asked about again, not taken for a lost terminal" do
    run = start_cloud(timeout: nil)
    poll(run)
    clear_enqueued_jobs
    requests = @conductor.requests.size

    travel(11.minutes) { WatchJob.perform_now(run.id, "silent") }
    assert run.reload.running?
    assert_nil run.runner_state["interrupted"]
    assert_enqueued_with(job: PollJob, args: [ run.id, 2 ])
    assert_equal requests, @conductor.requests.size
  end

  test "a session cut off while it was being started gets a new workspace, and one left behind is archived" do
    run = start_cloud(base: "main")
    # As the app going down between making the workspace and recording it leaves the run.
    run.update_columns(runner_state: run.runner_state.except("session"))
    @conductor.listed = [ { "id" => "ws-1", "name" => "harbor-run-#{run.id}", "state" => "ready" },
                          { "id" => "ws-old", "name" => "harbor-run-#{run.id}", "state" => "archived" },
                          { "id" => "ws-other", "name" => "harbor-run-#{run.id}0", "state" => "ready" } ]
    poll(run)
    assert_equal [ "POST /v0/workspaces" ], @conductor.sent, "with no workspace recorded there is nothing to ask"

    travel(11.minutes) { WatchJob.perform_now(run.id, "silent") }
    assert_equal "it was cut off while being started", run.reload.runner_state.dig("interrupted", "reason")
    WatchJob.perform_now(run.id, "resume")

    run.reload
    assert run.running?
    assert_equal [ "GET /v0/workspaces", "POST /v0/workspaces/ws-1/archive", "POST /v0/workspaces" ], @conductor.sent.last(3)
    assert_equal({ "name" => "harbor-run-#{run.id}", "repo" => "https://github.com/acme/app", "offset" => "0", "limit" => "100" },
                 @conductor.last("GET /v0/workspaces").params)
    assert_equal [ "harbor-run-#{run.id}-3", "main" ], created.values_at("name", "branch"), "named for the attempt it is"
    assert_match(/\n\n---\n\nFix the test\.\z/, created["message"])
    assert_equal [ "ws-2", "sess-2" ], run.runner_state["session"].values_at("workspace_id", "session_id")
    assert_equal "setup", progress(run)["phase"]

    @conductor.say(INIT, DONE)
    poll(run)
    assert run.reload.ok?
  end
end
