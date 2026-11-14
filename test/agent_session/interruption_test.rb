require "test_helper"

# A session cut off by a restart (of the machine it runs on, of Orca, of the
# app) is started again where it stopped instead of being finished.
class HarborAgentSessionInterruptionTest < ActionDispatch::IntegrationTest
  include HarborAgentSessions

  WatchJob = Harbor::AgentSession::WatchJob
  Interruption = Harbor::AgentSession::Interruption

  INIT = { type: "system", subtype: "init", session_id: "sess-1", model: "claude-sonnet-5-5-20261001" }.freeze
  RESULT = { type: "result", subtype: "success", is_error: false, total_cost_usd: 0.25, duration_ms: 9_000, num_turns: 4,
             result: "All done.", usage: { input_tokens: 100, output_tokens: 50 } }.freeze
  NO_SESSION = { type: "result", subtype: "error_during_execution", is_error: true, num_turns: 0,
                 errors: [ "No conversation found with session ID: sess-1" ] }.freeze

  def fetch_file(run, name, attempt: nil)
    post "/harbor/runner/runs/#{run.id}/bundle/#{name}#{"?attempt=#{attempt}" if attempt}", headers: runner_headers(run)
    response.body
  end

  # The words of the agent command the nth terminal was given.
  def agent_command(index) = Shellwords.split(Shellwords.split(@orca.terminal_commands.fetch(index)).last).join(" ")

  def runner_attempt(index) = @orca.terminal_commands.fetch(index)[/HARBOR_RUNNER_ATTEMPT=(\d+)/, 1].to_i

  # The session's terminal goes away with no result, and the silent check
  # finds out.
  def lose_terminal(run, after: 11.minutes)
    @orca.exited = true
    after.zero? ? WatchJob.perform_now(run.id, "silent") : travel(after) { WatchJob.perform_now(run.id, "silent") }
    @orca.exited = false
    run.reload
  end

  def resume_now(run) = WatchJob.perform_now(run.id, "resume")

  test "a session whose terminal went away is not finished: it is started again in its worktree, continuing its conversation" do
    finished = []
    Harbor.config.agent_session_finished = ->(run) { finished << run.status }
    run = start_session
    first = ndjson(INIT)
    post_output run, first

    travel 11.minutes
    freeze_time do
      lose_terminal(run, after: 0)
      assert run.running?, "the work is not over"
      assert_equal "its terminal went away without a result", run.runner_state.dig("interrupted", "reason")
      assert_equal "sess-1", run.runner_state.dig("interrupted", "session_id")
      assert_equal [ 2, 0, 0, first.bytesize, 1 ],
                   run.runner_state.values_at("attempt", "received", "digested", "raw_base", "interruptions")
      assert_enqueued_with(job: WatchJob, args: [ run.id, "resume" ])
      assert_match "[harbor] interrupted: its terminal went away without a result. Starting it again where it stopped.", live_log(run)
    end

    resume_now(run)
    run.reload
    assert run.running?
    assert_nil run.runner_state["interrupted"]
    assert_equal [ "terminal close", "terminal create" ], @orca.commands.last(2)
    assert_equal [ "--worktree", "id:repo-1::/work/harbor-run-#{run.id}", "--all" ], @orca.calls[-2][3, 3],
                 "everything left in the run's worktree is closed before a command starts there again"
    assert_equal "term-2", run.runner_state.dig("session", "terminal")
    assert_equal "repo-1::/work/harbor-run-#{run.id}", run.runner_state.dig("session", "worktree_id"), "the same worktree"
    assert agent_command(1).end_with?(" --resume sess-1"), agent_command(1)
    assert_equal 3, runner_attempt(1)
    assert_match(/ --resume sess-1\z/, run.command)
    assert_equal Interruption::CONTINUE, fetch_file(run, "prompt", attempt: 3)
    assert_no_match(/earlier attempt/, fetch_file(run, "system", attempt: 3))
    assert_match "[harbor] started again after the interruption (its terminal went away without a result): continuing its session sess-1",
                 live_log(run)
    assert_empty finished, "the host hears about a session once, when it has ended"
  end

  test "what the cut-off runner still sends is refused, and the new one's output and result finish the run" do
    run = start_session
    post_output run, ndjson(INIT)
    lose_terminal(run)
    resume_now(run)

    post_output run, "late\n", offset: 0, attempt: 1
    assert_response :conflict
    assert_equal "stale", response.body
    post_result run, 143, signalled: true, attempt: 1
    assert run.reload.running?, "a result from the attempt that was cut off ends nothing"

    post_output run, ndjson(INIT, RESULT), offset: 0, attempt: 3
    assert_response :no_content
    post_result run, 0, attempt: 3
    run.reload
    assert run.ok?
    assert_equal "All done.", run.output["text"]
    assert_equal BigDecimal("0.25"), run.cost_usd_actual
    assert_equal "sess-1", run.session_id
    assert_equal ndjson(INIT) + ndjson(INIT, RESULT), raw_stream(run), "both attempts are in the raw stream, one after the other"
    assert_equal "worktree rm", @orca.commands.last
  end

  test "a runner signalled out of its command when Harbor had not stopped it was interrupted, not ended" do
    run = start_session
    post_output run, ndjson(INIT)
    post_result run, 143, signalled: true
    assert_response :no_content
    run.reload
    assert run.running?
    assert_equal "its terminal was closed under it", run.runner_state.dig("interrupted", "reason")
    assert_equal [ "worktree create", "terminal create" ], @orca.commands, "nothing is asked of Orca inside the runner's own request"

    resume_now(run)
    assert agent_command(1).end_with?(" --resume sess-1")
  end

  test "a session Harbor stopped, or a command that ended by itself, is never started again" do
    stopped = start_session
    Harbor::AgentSession.stop!(stopped)
    post_result stopped, 143, signalled: true
    assert stopped.reload.canceled?

    failed = start_session
    post_result failed, 1
    assert failed.reload.error?

    done = start_session
    post_result done, 0, signalled: true
    assert done.reload.ok?, "it had finished when the signal came"
    assert_empty enqueued_jobs.select { |job| job["arguments"][1] == "resume" }
  end

  test "a session with no conversation to continue starts over in the same worktree, told what happened" do
    run = start_session(prompt: "Fix the test.")
    lose_terminal(run)
    assert_nil run.runner_state.dig("interrupted", "session_id")
    resume_now(run)
    run.reload

    assert_equal agent_command(0), agent_command(1), "the same command"
    assert_equal "Fix the test.", fetch_file(run, "prompt", attempt: 3)
    assert fetch_file(run, "system", attempt: 3).end_with?(Interruption::STARTED_OVER)
    assert_match "from its first prompt, in the same worktree", live_log(run)
  end

  test "codex has no session to continue by id, and a slash command is expanded again when starting over" do
    @alias.model_choices.first.update!(model_provider: @openai, model: "gpt-5.2")
    codex = start_session(choice: @alias.model_choices.first.reload, allowed_tools: [])
    post_output codex, ndjson(type: "thread.started", thread_id: "thread-1")
    lose_terminal(codex)
    resume_now(codex)
    assert_equal agent_command(0), agent_command(1)
    assert codex.reload.runner_state["started_over"]

    slash = start_session(prompt: nil, slash_command: "/tidy:shelf 12", command_ref: "origin/main")
    lose_terminal(slash)
    resume_now(slash)
    assert_equal agent_command(2), agent_command(3)
    assert_includes @orca.terminal_commands.last, "HARBOR_RUNNER_BUNDLE=arguments\\ system\\ mcp\\ env"
  end

  test "a slash command session that had a conversation continues it, and is not given its command again" do
    run = start_session(prompt: nil, slash_command: "/tidy:shelf 12", command_ref: "origin/main")
    post_output run, ndjson(INIT)
    lose_terminal(run)
    resume_now(run)

    assert_no_match(/tidy/, agent_command(1))
    assert_includes @orca.terminal_commands.last, "HARBOR_RUNNER_BUNDLE=prompt\\ system\\ mcp\\ env"
    assert_equal Interruption::CONTINUE, fetch_file(run, "prompt", attempt: 3)
  end

  test "while Orca can't be asked the session waits, and is started when it answers" do
    run = start_session
    post_output run, ndjson(INIT)
    lose_terminal(run)
    clear_enqueued_jobs

    freeze_time do
      2.times do
        @orca.refuse("terminal close", code: "runtime_unavailable")
        resume_now(run)
        assert_enqueued_with(job: WatchJob, args: [ run.id, "resume" ], at: 1.minute.from_now)
      end
    end
    run.reload
    assert run.running?
    assert_nil run.runner_state.dig("interrupted", "starting_at"), "the failed try holds nothing"
    assert_equal 1, live_log(run).scan("could not start it again yet").size, "said once, not every minute"
    assert_equal 1, @orca.terminal_commands.size

    resume_now(run)
    assert_nil run.reload.runner_state["interrupted"]
    assert_equal 2, @orca.terminal_commands.size
    assert_equal 5, runner_attempt(1), "each try is an attempt of its own, so a terminal from a lost one is refused"
  end

  test "a start that is under way is not started beside, and one never recorded is tried again later" do
    run = start_session
    lose_terminal(run)
    state = run.runner_state
    run.update_columns(runner_state: state.merge("interrupted" => state["interrupted"].merge("starting_at" => Time.current.iso8601)))

    resume_now(run)
    assert_equal 1, @orca.terminal_commands.size
    travel(Interruption::CLAIM + 1.minute) { resume_now(run) }
    assert_equal 2, @orca.terminal_commands.size
  end

  test "a session that can't be started again for hours is finished as an error, saying why" do
    finished = []
    Harbor.config.agent_session_finished = ->(run) { finished << run.status }
    run = start_session(timeout: nil)
    lose_terminal(run)
    @orca.refuse("terminal close", code: "runtime_unavailable")
    resume_now(run)

    travel(Interruption::WINDOW + 12.minutes) { resume_now(run) }
    run.reload
    assert run.error?
    assert_match(/\AThe session was interrupted \(its terminal went away without a result\) and could not be started again within 6 hours: /, run.error)
    assert_match "runtime_unavailable", run.error
    assert_equal [ "error" ], finished
  end

  test "a session is started again only as often as the setting allows" do
    Harbor::Setting.set!(:agent_session_resume_attempts, 1)
    run = start_session(timeout: nil)
    post_output run, ndjson(INIT)
    lose_terminal(run)
    resume_now(run)
    assert run.reload.running?

    lose_terminal(run, after: 30.minutes)
    assert run.error?
    assert_match(/\AThe runner stopped reporting/, run.error)
  end

  test "the time a session spent interrupted is not counted against its timeout, and nothing stops it meanwhile" do
    freeze_time do
      run = start_session(timeout: 30.minutes, idle_timeout: 5.minutes)
      was = Time.zone.parse(run.runner_state["timeout_at"])
      travel 12.minutes
      lose_terminal(run, after: 0)

      travel 40.minutes
      WatchJob.perform_now(run.id, "timeout")
      WatchJob.perform_now(run.id, "idle")
      WatchJob.perform_now(run.id, "silent")
      assert run.reload.running?, "past its timeout and idle limit, but interrupted"

      resume_now(run)
      run.reload
      assert_equal was + 40.minutes, Time.zone.parse(run.runner_state["timeout_at"])
      WatchJob.perform_now(run.id, "idle")
      assert run.reload.running?, "being started again counts as being heard from"

      travel 19.minutes
      WatchJob.perform_now(run.id, "timeout")
      assert run.reload.timeout?, "18 minutes were left when it was cut off"
    end
  end

  test "a stop still ends an interrupted session" do
    run = start_session
    lose_terminal(run)
    Harbor::AgentSession.stop!(run)
    assert run.reload.canceled?
    resume_now(run)
    assert_equal 1, @orca.terminal_commands.size
  end

  test "a session cut off while it was being started gets a new worktree and starts from its prompt" do
    run = start_session(base: "main")
    # As the app going down between claiming the run and recording its terminal leaves it.
    run.update_columns(runner_state: run.runner_state.except("session"))
    clear_enqueued_jobs

    freeze_time do
      travel 4.minutes
      WatchJob.perform_now(run.id, "silent")
      assert_nil run.reload.runner_state["interrupted"], "it may still be starting"
      assert_enqueued_with(job: WatchJob, args: [ run.id, "silent" ], at: 6.minutes.from_now)

      travel 7.minutes
      WatchJob.perform_now(run.id, "silent")
    end
    assert_equal "it was cut off while being started", run.reload.runner_state.dig("interrupted", "reason")

    resume_now(run)
    run.reload
    assert_equal [ "worktree rm", "worktree create", "terminal create" ], @orca.commands.last(3)
    assert_equal [ "--worktree", "name:harbor-run-#{run.id}" ], @orca.calls[-3][3, 2], "a worktree left by the first start is removed by name"
    create = @orca.calls[-2]
    assert_equal "main", create[create.index("--base-branch") + 1]
    assert_equal "term-2", run.runner_state.dig("session", "terminal")
    assert_equal "Fix the test.", fetch_file(run, "prompt", attempt: 3)
  end

  test "a session whose worktree the server no longer knows starts in a new one" do
    run = start_session
    post_output run, ndjson(INIT)
    lose_terminal(run)
    @orca.refuse("terminal close", code: "selector_not_found")
    @orca.refuse("worktree rm", code: "selector_not_found")
    resume_now(run)

    assert_equal [ "terminal close", "worktree rm", "worktree create", "terminal create" ], @orca.commands.last(4)
    assert_nil run.reload.runner_state["interrupted"]
  end

  test "a continued conversation that turns out to be gone starts over from the first prompt" do
    run = start_session(prompt: "Fix the test.")
    post_output run, ndjson(INIT)
    lose_terminal(run)
    resume_now(run)

    post_output run, ndjson(NO_SESSION), offset: 0, attempt: 3
    post_result run, 1, attempt: 3
    run.reload
    assert run.running?
    assert_equal 3, @orca.terminal_commands.size
    assert_no_match(/--resume/, agent_command(2))
    assert_equal "Fix the test.", fetch_file(run, "prompt", attempt: 4)
    assert fetch_file(run, "system", attempt: 4).end_with?(Interruption::STARTED_OVER)
  end

  # --- the runner's word that it is still there ---

  test "an empty post says the runner is there without counting as output" do
    freeze_time do
      run = start_session(timeout: nil, idle_timeout: 5.minutes)
      post_output run, ndjson(INIT)
      seen = run.reload.runner_state["last_seen_at"]

      travel 9.minutes
      post_output run, ""
      assert_response :no_content
      run.reload
      assert_equal seen, run.runner_state["last_seen_at"]
      assert_equal Time.current.iso8601, run.runner_state["alive_at"]

      @orca.exited = true
      travel 2.minutes
      calls = @orca.calls.size
      WatchJob.perform_now(run.id, "silent")
      assert_equal calls, @orca.calls.size, "heard from two minutes ago: its terminal is not asked about"
      assert_nil run.reload.runner_state["interrupted"]

      WatchJob.perform_now(run.id, "idle")
      assert run.reload.timeout?, "but its command printed nothing for longer than its idle limit"
    end
  end

  # --- after the app was down ---

  test "recover! queues every running session's checks again as a new round, and a check from an earlier round stops" do
    run = start_session(timeout: 30.minutes, idle_timeout: 5.minutes)
    other = start_session(timeout: nil)
    finished = start_session
    post_result finished, 0
    plain = Harbor::Run.create!(skill: "loader", status: "running")
    clear_enqueued_jobs

    freeze_time do
      assert_equal [ run.id, other.id ].sort, Harbor::AgentSession.recover!.map(&:id).sort
      %w[timeout idle silent].each do |check|
        assert_enqueued_with(job: WatchJob, args: [ run.id, check, 1 ], at: 2.minutes.from_now)
      end
      assert_enqueued_with(job: WatchJob, args: [ other.id, "silent", 1 ], at: 2.minutes.from_now)
      assert_equal 4, enqueued_jobs.size, "nothing for a finished session or a run that isn't one: #{plain.id}"
    end

    # The check queued when the session started belongs to no round now.
    @orca.exited = true
    travel(11.minutes) { WatchJob.perform_now(other.id, "silent") }
    assert_nil other.reload.runner_state["interrupted"]

    clear_enqueued_jobs
    travel(11.minutes) { WatchJob.perform_now(other.id, "silent", 1) }
    assert other.reload.runner_state["interrupted"].present?
    assert_enqueued_with(job: WatchJob, args: [ other.id, "resume", 1 ])
    assert_enqueued_with(job: WatchJob, args: [ other.id, "silent", 1 ]) # the round's checks carry on
  end

  test "recover! tries a session that was interrupted and never started again" do
    run = start_session
    lose_terminal(run)
    clear_enqueued_jobs

    Harbor::AgentSession.recover!
    assert_enqueued_with(job: WatchJob, args: [ run.id, "resume", 1 ])
    perform_enqueued_jobs(only: ->(job) { job["arguments"][1] == "resume" })
    assert_nil run.reload.runner_state["interrupted"]
    assert_equal 2, @orca.terminal_commands.size
  end

  test "run! asked again for a run that is already a session starts nothing and takes nothing" do
    run = Harbor::AgentSession.run!(agent: @agent, prompt: "Fix the test.")
    assert_equal 1, Harbor::Slots.busy(@agent)

    again = Harbor::AgentSession.run!(agent: @agent, prompt: "Fix the test.", run:)
    assert_equal run.id, again.id
    assert_equal 1, Harbor::Slots.busy(@agent)
    assert_equal 1, @orca.terminal_commands.size

    post_result run, 0
    assert_equal run.id, Harbor::AgentSession.run!(agent: @agent, prompt: "Fix the test.", run: run.reload).id
    assert_equal 1, @orca.terminal_commands.size
  end
end
