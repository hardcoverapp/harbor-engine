require "test_helper"

# Starting, stopping and timing out sessions, against a stand-in Orca.
class HarborAgentSessionTest < ActionDispatch::IntegrationTest
  include HarborAgentSessions
  include SingletonStub

  WatchJob = Harbor::AgentSession::WatchJob

  def wrapped_command(index = 0) = Shellwords.split(@orca.terminal_commands.fetch(index))

  def stored(run) = run.input.fetch("agent_session")

  # --- start! ---

  test "starting a session marks the run running, with what it runs on and where" do
    run = travel_to(Time.zone.parse("2026-11-12 10:00:00")) { start_session(base: "main") }

    assert run.running?
    assert_equal Time.zone.parse("2026-11-12 10:00:00"), run.started_at
    assert_equal [ "claude-sonnet-5-5", "medium", "orca", "Laptop", @runtime.id ],
                 [ run.model, run.effort, run.executor, run.runner_name, run.runtime_id ]
    assert_equal "claude -p <prompt…> --model claude-sonnet-5-5 --effort medium --allowedTools Read,Grep,Glob --dangerously-skip-permissions",
                 run.command
    assert_equal "writer-fix/run-#{run.id}.ndjson", run.raw_log_path
    assert_equal({ "worktree_id" => "repo-1::/work/harbor-run-#{run.id}", "worktree_path" => "/work/harbor-run-#{run.id}", "terminal" => "term-1" },
                 run.runner_state["session"])
    assert_equal [ "claude", "anthropic", 1, 0, 0 ], run.runner_state.values_at("cli", "provider", "attempt", "received", "digested")
    assert_equal Time.zone.parse("2026-11-12 10:30:00"), Time.zone.parse(run.runner_state["timeout_at"])
    assert Harbor::AgentSession.session?(run)
    assert_match "[harbor] claude -p <prompt…> --model claude-sonnet-5-5", live_log(run)
  end

  test "the terminal runs the wrapped agent command, told which files to fetch" do
    run = start_session(base: "main")

    create, terminal = @orca.calls
    assert_equal [ "worktree", "create", "--repo", "name:app", "--name", "harbor-run-#{run.id}", "--setup", "skip", "--base-branch", "main" ], create[1, 10]
    assert_equal "Writer · run #{run.id}", terminal[terminal.index("--title") + 1]
    words = wrapped_command
    assert_equal "HARBOR_RUNNER_URL=https://harbor.example.com/harbor/runner/runs/#{run.id}", words[0]
    assert Harbor::RunToken.valid?(words[1].delete_prefix("HARBOR_RUNNER_TOKEN="), run.id)
    assert_equal [ "HARBOR_RUNNER_BUNDLE=prompt system mcp env", "HARBOR_RUNNER_ATTEMPT=1", "sh", "-c", Harbor::Runner::SCRIPT, "harbor-runner" ], words[2, 6]
    command = Harbor::AgentSession::Command.new(cli: "claude", model: "claude-sonnet-5-5", effort: "medium", allowed_tools: %w[Read Grep Glob])
    assert_equal command.shell, words.last
    assert_no_match(/Fix the test|You write/, @orca.calls.to_json, "neither prompt is on a command line")
  end

  test "the agent is told its own instructions, that nobody is there, the host's line, then the caller's" do
    Harbor::AgentSetting.create!(key: Harbor::AgentSetting::HOUSE_CONTEXT, body: "House rules.")
    Harbor.config.agent_session_preamble = ->(run) { "You act as bot-account for run #{run.id}." }
    run = start_session(prompt: "Fix the test.", system_prompt_extra: "The task: #42.")

    assert_equal "Fix the test.", stored(run)["prompt"]
    assert_equal [ "House rules.\n\n---\n\nYou write.", Harbor::AgentSession::UNATTENDED, "You act as bot-account for run #{run.id}.", "The task: #42." ].join("\n\n"),
                 stored(run)["system"]
    assert_match "Never ask a question", Harbor::AgentSession::UNATTENDED
    assert_match "print a line starting with ERROR:", Harbor::AgentSession::UNATTENDED
    assert_match "exit non-zero", Harbor::AgentSession::UNATTENDED

    Harbor.config.agent_session_preamble = nil
    plain = start_session
    assert_equal "House rules.\n\n---\n\nYou write.\n\n#{Harbor::AgentSession::UNATTENDED}", stored(plain)["system"]
  end

  test "the agent's own tool rules apply unless the caller gives others" do
    @agent.update!(tools: { "allowed" => %w[Read], "permission_mode" => "plan" })
    own = start_session
    assert_match "--allowedTools Read --permission-mode plan", own.command
    assert_includes wrapped_command(0).last, "--allowedTools Read "

    given = start_session(allowed_tools: nil, disallowed_tools: %w[Bash], permission_mode: "default", add_dirs: [ "/srv/docs" ],
                          resume_session_id: "abc-1")
    assert_equal "claude -p <prompt…> --model claude-sonnet-5-5 --effort medium --disallowedTools Bash --resume abc-1", given.command
    assert_match "--add-dir /srv/docs", wrapped_command(1).last
    assert_equal({ "cli" => "claude", "model" => "claude-sonnet-5-5", "effort" => "medium", "permission_mode" => "default", "allowed_tools" => [],
                   "disallowed_tools" => [ "Bash" ], "add_dirs" => [ "/srv/docs" ], "resume_session_id" => "abc-1" }, stored(given)["command"])
  end

  test "an OpenAI model's session runs through codex" do
    gpt = Harbor::ModelAlias.create!(name: "Other", model_choices_attributes: [ { model_provider: @openai, model: "gpt-5.5", effort: "high", position: 0 } ])
    run = Harbor::AgentSession.start!(run: new_run, agent: @agent, prompt: "Read it.", runtime: @runtime, choice: gpt.model_choices.first)

    assert run.running?
    assert_equal [ "codex", "openai" ], run.runner_state.values_at("cli", "provider")
    assert_equal "codex exec <prompt…> --sandbox read-only --model gpt-5.5 --effort high", run.command
    assert_match(/\| codex exec --json --skip-git-repo-check --sandbox read-only /, wrapped_command.last)
  end

  test "the checks that end a session are scheduled when it starts" do
    freeze_time do
      run = start_session(timeout: 20.minutes, idle_timeout: 5.minutes)
      assert_enqueued_with(job: WatchJob, args: [ run.id, "timeout" ], at: 20.minutes.from_now)
      assert_enqueued_with(job: WatchJob, args: [ run.id, "idle" ], at: 5.minutes.from_now)
      assert_enqueued_with(job: WatchJob, args: [ run.id, "silent" ], at: 10.minutes.from_now)
      assert_equal 300, run.runner_state["idle_timeout"]
    end
    clear_enqueued_jobs
    start_session
    assert_equal %w[timeout silent], enqueued_jobs.map { |job| job["arguments"].last }, "no idle check unless asked for"
  end

  test "a session whose terminal can't be started is finished as an error, with nothing left behind" do
    finished = []
    Harbor.config.agent_session_finished = ->(run) { finished << run.status }
    owner = "run:test"
    slots = { "owner" => owner, "agent" => { "key" => "writer", "slot" => Harbor::Slots.acquire(@agent, owner, ttl: 600) },
              "runtime" => { "key" => "laptop", "slot" => Harbor::Runtimes::Slots.acquire(@runtime, owner, ttl: 600) } }
    @orca.refuse("terminal create")

    run = start_session(slots:)
    assert run.error?
    assert_match "The agent session could not be started: orca terminal create: refused: runtime_unavailable", run.error
    assert_equal [ "worktree create", "terminal create", "worktree rm" ], @orca.commands, "the worktree made for it is removed"
    assert_equal [ 0, 0 ], [ Harbor::Slots.busy(@agent), @runtime.busy ], "its slots are given back"
    assert_equal [ "error" ], finished
    assert_no_enqueued_jobs
  end

  test "a failure after the terminal started closes it and removes the worktree" do
    with_stub(WatchJob, :set, ->(*) { raise "the queue is down" }) do
      run = start_session
      assert run.error?
      assert_match "the queue is down", run.error
      assert_equal [ "worktree create", "terminal create", "terminal close", "worktree rm" ], @orca.commands
    end
  end

  test "tool rules codex can't enforce stop the session before anything is made" do
    gpt = Harbor::ModelAlias.create!(name: "Other", model_choices_attributes: [ { model_provider: @openai, model: "gpt-5.5", position: 0 } ])
    run = Harbor::AgentSession.start!(run: new_run, agent: @agent, prompt: "x", runtime: @runtime, choice: gpt.model_choices.first,
                                      disallowed_tools: %w[WebSearch])
    assert run.error?
    assert_match "Codex cannot enforce this disallowedTools policy", run.error
    assert_empty @orca.calls
  end

  test "a runtime whose backend doesn't start commands can't take a session" do
    Harbor::Runtimes.register "plain", "Harbor::Runtimes::Backend"
    other = Harbor::Runtime.create!(key: "other", name: "Other", backend: "plain")
    run = Harbor::AgentSession.start!(run: new_run, agent: @agent, prompt: "x", runtime: other, choice: @choice)
    assert run.error?
    assert_match "Other can't run agent sessions", run.error
  ensure
    Harbor::Runtimes.unregister "plain"
  end

  test "a run is started as a session once" do
    run = start_session
    state = run.runner_state
    assert_raises(Harbor::AgentSession::AlreadyStarted) { start_session(run:) }
    assert_equal state, run.reload.runner_state
    assert run.running?
    assert_equal 1, @orca.terminal_commands.size

    done = new_run(status: "ok")
    assert_raises(Harbor::AgentSession::AlreadyStarted) { start_session(run: done) }
    assert done.reload.ok?
  end

  # --- run! ---

  test "run! makes the run, places it, takes a slot on the runtime and one of the agent's, and starts it" do
    run = Harbor::AgentSession.run!(agent: @agent, prompt: "Fix the test.", attributes: { skill: "writer.fix", task_type: "fix" }, timeout: 20.minutes)

    assert run.running?
    assert_equal [ "writer", "writer.fix", "fix", @runtime.id, "claude-sonnet-5-5" ], [ run.agent_key, run.skill, run.task_type, run.runtime_id, run.model ]
    assert_equal({ "owner" => "run:#{run.id}", "agent" => { "key" => "writer", "slot" => 0 }, "runtime" => { "key" => "laptop", "slot" => 0 } },
                 run.runner_state["slots"])
    assert_equal [ 1, 1 ], [ Harbor::Slots.busy(@agent), @runtime.busy ]
    assert_match "[harbor] using Laptop", live_log(run)
    assert_equal 1, @orca.terminal_commands.size

    post_result run, 0
    assert run.reload.ok?
    assert_equal [ 0, 0 ], [ Harbor::Slots.busy(@agent), @runtime.busy ], "finishing gives both back"
  end

  test "a run with nothing but an agent still has a log" do
    run = Harbor::AgentSession.run!(agent: @agent, prompt: "Fix the test.")
    assert_equal "writer/run-#{run.id}.log", run.live_log_path
    assert_equal "writer/run-#{run.id}.ndjson", run.raw_log_path
  end

  test "when the agent is at its limit the run waits, holding nothing" do
    @agent.update!(max_agents: 1)
    first = Harbor::AgentSession.run!(agent: @agent, prompt: "one")
    second = Harbor::AgentSession.run!(agent: @agent, prompt: "two")

    assert first.running?
    assert second.queued?
    assert_not Harbor::AgentSession.session?(second)
    assert_match "[harbor] waiting: Writer is already running as many sessions as it may.", live_log(second)
    assert_equal [ 1, 1 ], [ Harbor::Slots.busy(@agent), @runtime.busy ]
    assert_equal 1, @orca.terminal_commands.size

    post_result first, 0
    again = Harbor::AgentSession.run!(agent: @agent, prompt: "two", run: second)
    assert_equal second.id, again.id
    assert again.running?, "the same run starts once there is room"
  end

  test "when every runtime is full the run waits, and the agent's slot is given back" do
    @runtime.update!(max_concurrent: 1)
    Harbor::AgentSession.run!(agent: @agent, prompt: "one")
    waiting = Harbor::AgentSession.run!(agent: @agent, prompt: "two")

    assert waiting.queued?
    assert_match "[harbor] waiting: Every runtime that could take this is full: Laptop: 1/1 busy", live_log(waiting)
    assert_equal [ 1, 1 ], [ Harbor::Slots.busy(@agent), @runtime.busy ]
  end

  test "when no model is available the run waits for one, holding nothing" do
    @anthropic.update!(enabled: false)
    run = Harbor::AgentSession.run!(agent: @agent, prompt: "one")

    assert run.waiting_for_model?
    assert_match "[harbor] waiting: No runtime in the Default workspace can run writer", live_log(run)
    assert_equal [ 0, 0 ], [ Harbor::Slots.busy(@agent), @runtime.busy ]
    assert_empty @orca.calls
  end

  test "run! passes the session's options on, and a failed start gives the slots back" do
    @orca.refuse("worktree create", code: "selector_not_found")
    run = Harbor::AgentSession.run!(agent: @agent, prompt: "one", disallowed_tools: %w[Bash], keep_worktree: true)
    assert run.error?
    assert_equal [ 0, 0 ], [ Harbor::Slots.busy(@agent), @runtime.busy ]

    kept = Harbor::AgentSession.run!(agent: @agent, prompt: "one", disallowed_tools: %w[Bash], keep_worktree: true, base: "release")
    assert_match "--disallowedTools Bash", kept.command
    assert_equal true, kept.runner_state["keep_worktree"]
    assert_includes @orca.calls[-2], "release"
  end

  # --- stop! ---

  test "stopping a session closes its terminal and finishes the run without waiting for a result" do
    finished = []
    Harbor.config.agent_session_finished = ->(run) { finished << run.status }
    run = start_session
    post_output run, ndjson({ type: "system", subtype: "init", session_id: "sess-1", model: "m" }) + '{"type":"assistant","mess'

    assert_equal run, Harbor::AgentSession.stop!(run)
    run.reload
    assert run.canceled?
    assert_equal "canceled", run.runner_state["stop_reason"]
    assert_nil run.error
    assert_equal "sess-1", run.session_id
    assert_equal [ "worktree create", "terminal create", "terminal close", "terminal close", "worktree rm" ], @orca.commands
    assert_equal %w[terminal close --terminal term-1], @orca.calls[2][1, 4]
    assert_equal [ "canceled" ], finished
    assert_match '{"type":"assistant","mess', live_log(run), "what had arrived, cut off or not, is in the log"
  end

  test "stopping twice, or stopping a finished run, does nothing more" do
    run = start_session
    Harbor::AgentSession.stop!(run, reason: "timeout", note: "Stopped: too long.")
    commands = @orca.commands.dup
    Harbor::AgentSession.stop!(run)
    Harbor::AgentSession.stop!(run.reload, reason: "canceled")

    assert run.reload.timeout?, "the first reason stands"
    assert_equal "Stopped: too long.", run.error
    assert_equal commands, @orca.commands

    done = new_run(status: "ok")
    Harbor::AgentSession.stop!(done)
    assert done.reload.ok?
    assert_raises(ArgumentError) { Harbor::AgentSession.stop!(start_session, reason: "ok") }
  end

  test "a session is finished even when its terminal can't be closed" do
    run = start_session
    @orca.refuse("terminal close", code: "runtime_unavailable")
    Harbor::AgentSession.stop!(run)
    assert run.reload.canceled?
    assert_match "[harbor] closing the terminal failed", live_log(run)
    assert_equal "worktree rm", @orca.commands.last
  end

  test "a run that is still waiting can be stopped too" do
    run = new_run
    Harbor::AgentSession.stop!(run)
    assert run.reload.canceled?
    assert_empty @orca.calls
  end

  # --- timeouts ---

  test "a session still running when its time is up is stopped as a timeout" do
    run = start_session(timeout: 20.minutes)
    travel 20.minutes + 1.second do
      WatchJob.perform_now(run.id, "timeout")
    end
    run.reload
    assert run.timeout?
    assert_equal "Stopped: it had 20 minutes and was still running.", run.error
    assert_includes @orca.commands, "terminal close"
    assert_includes @orca.commands, "worktree rm"
  end

  test "the timeout check is harmless early, late, twice, or after the session ended" do
    run = start_session(timeout: 20.minutes)
    clear_enqueued_jobs
    freeze_time do
      travel 5.minutes
      WatchJob.perform_now(run.id, "timeout")
      assert run.reload.running?, "early: it looks again when the time is really up"
      assert_enqueued_with(job: WatchJob, args: [ run.id, "timeout" ], at: 15.minutes.from_now)
    end

    travel 3.hours do
      WatchJob.perform_now(run.id, "timeout")
      commands = @orca.commands.dup
      ended = run.reload.ended_at
      clear_enqueued_jobs
      WatchJob.perform_now(run.id, "timeout")
      WatchJob.perform_now(run.id, "idle")
      WatchJob.perform_now(run.id, "silent")
      assert run.reload.timeout?
      assert_equal [ ended, commands ], [ run.ended_at, @orca.commands ]
      assert_no_enqueued_jobs
    end

    finished = start_session(timeout: 20.minutes)
    post_result finished, 0
    travel(1.hour) { WatchJob.perform_now(finished.id, "timeout") }
    assert finished.reload.ok?
    WatchJob.perform_now(0, "timeout")
    WatchJob.perform_now(start_session.id, "no-such-check")
  end

  test "a session that prints nothing for its idle limit is stopped, and one that keeps printing is not" do
    run = start_session(idle_timeout: 5.minutes)
    clear_enqueued_jobs
    freeze_time do
      travel 4.minutes
      post_output run, "still working\n"
      travel 2.minutes
      WatchJob.perform_now(run.id, "idle")
      assert run.reload.running?, "six minutes in, but heard from two minutes ago"
      assert_enqueued_with(job: WatchJob, args: [ run.id, "idle" ], at: 3.minutes.from_now)

      travel 3.minutes + 1.second
      WatchJob.perform_now(run.id, "idle")
    end
    run.reload
    assert run.timeout?
    assert_equal "Stopped: nothing was printed for 5 minutes.", run.error

    quiet = start_session
    travel(2.hours) { WatchJob.perform_now(quiet.id, "idle") }
    assert quiet.reload.running?, "no idle limit, no idle stop"
  end

  test "a quiet session whose terminal has gone is finished as an error: the runner stopped reporting" do
    finished = []
    Harbor.config.agent_session_finished = ->(run) { finished << run.status }
    run = start_session(timeout: nil)
    post_output run, ndjson(type: "system", subtype: "init", session_id: "sess-1", model: "m")
    @orca.exited = true

    travel 10.minutes + 1.second do
      WatchJob.perform_now(run.id, "silent")
    end
    run.reload
    assert run.error?
    assert_match(/\AThe runner stopped reporting: nothing arrived for 10 minutes/, run.error)
    assert_equal [ "terminal", "wait", "--terminal", "term-1", "--for", "exit", "--timeout-ms", "1000" ], @orca.calls[2][1, 8]
    assert_equal "sess-1", run.session_id
    assert_equal [ "error" ], finished
    assert_equal "worktree rm", @orca.commands.last
  end

  test "a quiet session whose terminal is still busy is left alone" do
    run = start_session(timeout: nil)
    clear_enqueued_jobs
    freeze_time do
      travel 4.minutes
      WatchJob.perform_now(run.id, "silent")
      assert_equal 2, @orca.calls.size, "not quiet for long enough to ask"
      assert_enqueued_with(job: WatchJob, args: [ run.id, "silent" ], at: 6.minutes.from_now)

      travel 30.minutes
      WatchJob.perform_now(run.id, "silent")
      assert run.reload.running?, "an agent may think for a long time"
      assert_equal "terminal wait", @orca.commands.last
      assert_enqueued_with(job: WatchJob, args: [ run.id, "silent" ], at: 10.minutes.from_now)
    end
  end

  test "how long a session may be quiet before its terminal is asked about is a setting" do
    Harbor::Setting.set!(:agent_session_silent_minutes, 2)
    run = start_session(timeout: nil)
    @orca.exited = true
    travel(3.minutes) { WatchJob.perform_now(run.id, "silent") }
    assert run.reload.error?
  end

  test "a terminal that is gone altogether counts as ended, and a runtime that can't be asked decides nothing" do
    gone = start_session(timeout: nil)
    @orca.refuse("terminal wait", code: "terminal_handle_stale")
    travel(11.minutes) { WatchJob.perform_now(gone.id, "silent") }
    assert gone.reload.error?

    unknown = start_session(timeout: nil)
    clear_enqueued_jobs
    @orca.refuse("terminal wait", code: "runtime_unavailable")
    travel(11.minutes) do
      WatchJob.perform_now(unknown.id, "silent")
      assert unknown.reload.running?
      assert_enqueued_with(job: WatchJob, args: [ unknown.id, "silent" ])
    end
  end

  # --- the Orca backend ---

  test "the Orca backend enforces tool rules, and passes over an OpenAI model whose rules codex can't keep" do
    backend = Harbor::Runtimes::Backends::Orca
    gpt = Harbor::ModelChoice.new(model_provider: @openai, model: "gpt-5.5")
    assert backend.enforces_tool_policy?
    assert backend.supports?(@choice, allowed_tools: %w[Read WebFetch], disallowed_tools: %w[WebSearch]), "claude takes any rules"
    assert backend.supports?(gpt)
    assert backend.supports?(gpt, allowed_tools: %w[Read Grep Glob], disallowed_tools: %w[Edit Write NotebookEdit Bash Agent Task])
    assert_not backend.supports?(gpt, allowed_tools: %w[Read WebFetch])
    assert_not backend.supports?(gpt, disallowed_tools: %w[WebSearch])
    assert_nil backend.policy_hint(allowed_tools: %w[Read])
    assert_match "need an Anthropic model", backend.policy_hint(allowed_tools: %w[Bash])
  end

  test "placement on Orca falls back from an OpenAI model that can't keep the agent's rules" do
    @alias.update!(model_choices_attributes: [ { model_provider: @openai, model: "gpt-5.5", position: 0 },
                                               { id: @choice.id, position: 1 } ])
    assert_equal "gpt-5.5", @agent.placement.choice.model, "reading tools only: codex can keep that"
    @agent.update!(tools: { "allowed" => %w[Read Bash] })
    assert_equal "claude-sonnet-5-5", @agent.reload.placement(requirements: { tool_policy: true }).choice.model

    @anthropic.update!(enabled: false)
    error = assert_raises(Harbor::WorkspaceProfile::Unavailable) { @agent.reload.placement }
    assert_match "need an Anthropic model", error.message
  end

  test "the backend starts a new terminal in a session's worktree, and says whether a terminal has ended" do
    backend = @runtime.adapter
    run = new_run(status: "running")
    session = backend.start(run:, command: "make test")
    again = backend.restart(session, run:, command: "make again", attempt: 2)

    assert_equal [ session.worktree_id, session.worktree_path, "term-2" ], [ again.worktree_id, again.worktree_path, again.terminal ]
    assert_equal [ "worktree create", "terminal create", "terminal create" ], @orca.commands
    words = wrapped_command(1)
    assert_equal "make again", words.last
    assert_includes words, "HARBOR_RUNNER_ATTEMPT=2"

    assert_not backend.exited?(again)
    @orca.exited = true
    assert backend.exited?(again)
    @orca.refuse("terminal wait", code: "terminal_handle_stale")
    assert backend.exited?(again)
    @orca.refuse("terminal wait", code: "runtime_unavailable")
    assert_raises(Harbor::Orca::Error) { backend.exited?(again) }
  end
end
