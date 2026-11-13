require "test_helper"

# How a session ends: the runner's result, a stop, and everything that is
# put away afterwards.
class HarborAgentSessionFinisherTest < ActionDispatch::IntegrationTest
  include HarborAgentSessions

  INIT = { type: "system", subtype: "init", session_id: "sess-1", model: "claude-sonnet-5-5-20261001" }.freeze
  RESULT = { type: "result", subtype: "success", is_error: false, total_cost_usd: 0.4321, duration_ms: 45_400, num_turns: 6,
             result: "All done.", usage: { input_tokens: 2000, output_tokens: 600, cache_read_input_tokens: 9000,
                                           cache_creation_input_tokens: 200 } }.freeze
  NO_SESSION = { type: "result", subtype: "error_during_execution", is_error: true, num_turns: 0,
                 errors: [ "No conversation found with session ID: old-session" ] }.freeze

  setup do
    @finished = []
    Harbor.config.agent_session_finished = ->(run) { @finished << [ run.id, run.status ] }
  end

  test "a result writes everything the stream said onto the run" do
    run = start_session
    post_output run, ndjson(INIT, RESULT)
    travel_to(Time.zone.parse("2026-11-12 10:00:00")) { post_result run, 0 }
    assert_response :no_content
    run.reload

    assert run.ok?
    assert_nil run.error
    assert_nil run.error_class
    assert_equal Time.zone.parse("2026-11-12 10:00:00"), run.ended_at
    assert_equal "sess-1", run.session_id
    assert_equal "claude-sonnet-5-5-20261001", run.model, "the model the stream named"
    assert_equal BigDecimal("0.4321"), run.cost_usd_actual
    assert_equal 45_400, run.duration_ms
    assert_equal [ 2000, 600, 9000, 200 ], [ run.input_tokens, run.output_tokens, run.cache_read_tokens, run.cache_creation_tokens ]
    assert_equal({ "exit_code" => 0, "text" => "All done." }, run.output)
    assert_equal 0, run.runner_state["exit_status"]
    assert_match(/<!-- run finished at .*: ok -->\n\z/, live_log(run))
    assert_equal [ [ run.id, "ok" ] ], @finished
  end

  test "a stream that names no model leaves the run's own" do
    run = start_session
    post_output run, ndjson(RESULT)
    post_result run, 0
    assert_equal "claude-sonnet-5-5", run.reload.model
    assert_nil run.session_id
  end

  test "a last line with no newline is still read" do
    run = start_session
    stream = ndjson(INIT, RESULT).chomp
    post_output run, stream
    assert_equal 1, run.run_events.count, "the result has no newline yet"
    post_result run, 0

    assert_equal %w[init success], run.run_events.ordered.pluck(:subtype)
    assert_match "[result] success · 45s · $0.43\n", live_log(run)
    assert_equal stream.bytesize, run.reload.runner_state["digested"]
    assert_equal "All done.", run.output["text"]
  end

  test "a failed command is an error, explained by what it printed outside the stream" do
    run = start_session
    post_output run, ndjson(INIT) + "Error: Invalid API key · Please run /login\nbash: exit 1\n"
    post_result run, 1
    run.reload

    assert run.error?
    assert_equal "Error: Invalid API key · Please run /login\nbash: exit 1", run.error
    assert_equal({ "exit_code" => 1, "text" => "Error: Invalid API key · Please run /login\nbash: exit 1" }, run.output)
    assert_nil run.error_class, "no result, so no kind of error result"
    assert_equal [ [ run.id, "error" ] ], @finished
  end

  test "a failed command that printed nothing of its own is named by its exit status" do
    run = start_session
    post_output run, ndjson(INIT, RESULT.merge(subtype: "error_max_turns", is_error: true, result: nil))
    post_result run, 1
    run.reload

    assert run.error?
    assert_equal "claude exited 1", run.error
    assert_equal "error_max_turns", run.error_class
    assert_equal({ "exit_code" => 1 }, run.output)
    assert_equal BigDecimal("0.4321"), run.cost_usd_actual, "what it cost is recorded all the same"
  end

  test "only the end of long plain output is kept as the error and the text" do
    run = start_session
    post_output run, (1..400).map { |i| "plain line #{i}\n" }.join
    post_result run, 2
    run.reload
    assert_operator run.error.length, :<=, 2000
    assert run.error.end_with?("plain line 400")
    assert_equal run.error, run.output["text"]
  end

  test "an error result alone does not fail a command that exited 0" do
    run = start_session
    post_output run, ndjson(INIT, RESULT.merge(subtype: "error_during_execution", is_error: true))
    post_result run, 0
    run.reload
    assert run.ok?
    assert_equal "error_during_execution", run.error_class
  end

  test "a reason Harbor recorded for stopping wins over whatever the command reports" do
    run = start_session
    post_output run, ndjson(INIT, RESULT)
    run.update_columns(runner_state: run.reload.runner_state.merge("stop_reason" => "canceled"))
    post_result run, 0
    assert run.reload.canceled?, "the stop was asked for first"
    assert_equal BigDecimal("0.4321"), run.cost_usd_actual
    assert_equal "All done.", run.output["text"]

    timed_out = start_session
    timed_out.update_columns(runner_state: timed_out.runner_state.merge("stop_reason" => "timeout", "stop_note" => "Stopped: too long."))
    post_result timed_out, 143, signalled: true
    assert timed_out.reload.timeout?
    assert_equal "Stopped: too long.", timed_out.error
    assert_equal true, timed_out.runner_state["signalled"]
  end

  test "finishing happens once: a second result changes nothing and the host is told once" do
    run = start_session
    post_output run, ndjson(INIT, RESULT)
    post_result run, 0
    ended = run.reload.ended_at
    commands = @orca.commands.dup

    travel 1.minute do
      post_result run, 1
      assert_response :no_content
      Harbor::AgentSession::Finisher.call(run, exit_status: 2)
      Harbor::AgentSession::Finisher.call(run.reload, error: "something else")
    end
    run.reload
    assert run.ok?
    assert_equal ended, run.ended_at
    assert_equal 0, run.output["exit_code"]
    assert_equal [ [ run.id, "ok" ] ], @finished
    assert_equal commands, @orca.commands, "and nothing is cleaned up twice"
    assert_equal 1, live_log(run).scan("run finished at").size
  end

  test "a result that arrives after a stop is ignored" do
    run = start_session
    post_output run, ndjson(INIT)
    Harbor::AgentSession.stop!(run)
    assert run.reload.canceled?

    post_output run, ndjson(RESULT), offset: ndjson(INIT).bytesize
    assert_response :conflict
    post_result run, 0
    assert_response :no_content
    run.reload
    assert run.canceled?
    assert_nil run.cost_usd_actual
    assert_equal [ [ run.id, "canceled" ] ], @finished
  end

  test "the terminal is closed, the worktree removed and the slots given back" do
    owner = "run:test"
    slots = { "owner" => owner,
              "agent" => { "key" => "writer", "slot" => Harbor::Slots.acquire(@agent, owner, ttl: 600) },
              "runtime" => { "key" => "laptop", "slot" => Harbor::Runtimes::Slots.acquire(@runtime, owner, ttl: 600) } }
    run = start_session(slots:)
    assert_equal [ 1, 1 ], [ Harbor::Slots.busy(@agent), @runtime.busy ]

    post_result run, 0
    assert_equal [ 0, 0 ], [ Harbor::Slots.busy(@agent), @runtime.busy ]
    assert_equal [ "worktree create", "terminal create", "terminal close", "worktree rm" ], @orca.commands
    assert_equal [ "worktree", "rm", "--worktree", "id:repo-1::/work/harbor-run-#{run.id}", "--force", "--delete-branch" ], @orca.calls.last[1, 6]
  end

  test "a worktree the caller asked to keep is left" do
    run = start_session(keep_worktree: true)
    post_result run, 0
    assert run.reload.ok?
    assert_equal [ "worktree create", "terminal create", "terminal close" ], @orca.commands
  end

  test "a cleanup that fails is logged and never leaves the run unfinished" do
    run = start_session
    @orca.refuse("terminal close", code: "runtime_unavailable")
    @orca.refuse("worktree rm", code: "worktree_busy")
    post_output run, ndjson(INIT, RESULT)
    post_result run, 0
    assert_response :no_content

    assert run.reload.ok?
    assert_equal [ [ run.id, "ok" ] ], @finished, "the host is still told"
    assert_match "[harbor] closing the terminal failed: orca terminal close: refused: runtime_unavailable", live_log(run)
    assert_match "[harbor] removing the worktree failed: orca worktree rm: refused: worktree_busy", live_log(run)
    assert_match(/run finished at .*: ok/, live_log(run))
  end

  test "a host follow-up that raises is logged and the run stays finished" do
    Harbor.config.agent_session_finished = ->(_run) { raise "the follow-up broke" }
    run = start_session
    post_result run, 0
    assert_response :no_content
    assert run.reload.ok?
    assert_match "agent_session_finished) failed: the follow-up broke", live_log(run)
  end

  test "a raw stream that has gone missing does not strand the run" do
    run = start_session
    post_output run, ndjson(INIT, RESULT)
    File.delete(Harbor::LiveLog.absolute(run.raw_log_path))
    post_result run, 0
    assert run.reload.ok?
    assert_nil run.cost_usd_actual
  end

  test "a run moved between models keeps adding to what it had used before" do
    usage = { "cost_usd_actual" => 1.0, "duration_ms" => 60_000, "input_tokens" => 100, "output_tokens" => 10,
              "cache_read_tokens" => 1000, "cache_creation_tokens" => 5 }
    run = new_run(input: { "model_switches" => [ { "usage" => { "cost_usd_actual" => 0.2 } }, { "usage" => usage } ] })
    start_session(run:)
    assert_equal "writer-fix/run-#{run.id}-attempt-3.ndjson", run.raw_log_path, "each attempt has its own stream, as it has its own log"
    post_output run, ndjson(INIT, RESULT)
    post_result run, 0
    run.reload

    assert_equal BigDecimal("1.4321"), run.cost_usd_actual
    assert_equal 105_400, run.duration_ms
    assert_equal [ 2100, 610, 10_000, 205 ], [ run.input_tokens, run.output_tokens, run.cache_read_tokens, run.cache_creation_tokens ]

    silent = new_run(input: { "model_switches" => [ { "usage" => usage } ] })
    start_session(run: silent)
    post_result silent, 1
    assert_equal BigDecimal("1.0"), silent.reload.cost_usd_actual, "an attempt that reported nothing leaves the earlier total"
  end

  # --- continuing a session that is gone ---

  def wrapped_command(index) = Shellwords.split(@orca.terminal_commands.fetch(index))

  test "a session that could not be continued is started once more without --resume, in the same worktree" do
    run = start_session(resume_session_id: "old-session")
    assert_includes wrapped_command(0).last, "--resume old-session"
    assert_equal "old-session", run.runner_state["resume_session_id"]

    first = ndjson(NO_SESSION)
    post_output run, first, attempt: 1
    post_result run, 1, attempt: 1
    assert_response :no_content
    run.reload

    assert run.running?, "the run is not finished: it gets another attempt"
    assert_empty @finished
    assert_equal [ "worktree create", "terminal create", "terminal close", "terminal create" ], @orca.commands
    again = @orca.calls.last
    assert_equal "id:repo-1::/work/harbor-run-#{run.id}", again[again.index("--worktree") + 1], "the same worktree"
    assert_not_includes wrapped_command(1).last, "--resume"
    assert_includes wrapped_command(1), "HARBOR_RUNNER_ATTEMPT=2"
    assert_equal "term-2", run.runner_state.dig("session", "terminal")
    assert_equal [ 2, 0, 0, first.bytesize, true ], run.runner_state.values_at("attempt", "received", "digested", "raw_base", "resume_fallback")
    assert_match "[harbor] --resume old-session did not continue (exit 1); starting again without it", live_log(run)
    assert_no_match(/--resume/, run.command)

    # The first runner's late posts belong to an attempt that is over.
    post_result run, 1, attempt: 1
    assert run.reload.running?
    post_output run, "late\n", offset: first.bytesize, attempt: 1
    assert_response :conflict

    post_output run, ndjson(INIT, RESULT), offset: 0, attempt: 2
    assert_response :no_content
    post_result run, 0, attempt: 2
    run.reload
    assert run.ok?
    assert_equal "sess-1", run.session_id
    assert_equal BigDecimal("0.4321"), run.cost_usd_actual, "the second attempt's stream is the one summed up"
    assert_nil run.error_class
    assert_equal first + ndjson(INIT, RESULT), raw_stream(run), "both attempts are in the raw stream"
    assert_equal [ 1, 2, 3 ], run.run_events.ordered.pluck(:seq), "and the events carry on from the first attempt's"
    assert_equal [ [ run.id, "ok" ] ], @finished
  end

  test "a slash command session started again without --resume expands its command again" do
    run = start_session(prompt: nil, slash_command: "/tidy:shelf 12 --fast", command_ref: "origin/main", resume_session_id: "old-session")
    first = wrapped_command(0)
    assert first.last.end_with?(" --resume old-session")

    post_output run, ndjson(NO_SESSION), attempt: 1
    post_result run, 1, attempt: 1
    run.reload

    assert run.running?
    second = wrapped_command(1)
    assert_equal first.last.delete_suffix(" --resume old-session"), second.last, "the same command, expansion and all, without --resume"
    assert_includes second.last, "git show origin/main:.claude/commands/tidy/shelf.md"
    assert_equal [ "HARBOR_RUNNER_BUNDLE=arguments system mcp env", "HARBOR_RUNNER_ATTEMPT=2" ], second[2, 2]
    assert_equal "claude -p /tidy:shelf 12 --fast --model claude-sonnet-5-5 --effort medium --allowedTools Read,Grep,Glob --dangerously-skip-permissions",
                 run.command
    assert_equal [ "/tidy:shelf 12 --fast", "origin/main" ], run.input.dig("agent_session", "command").values_at("slash_command", "command_ref")

    post "/harbor/runner/runs/#{run.id}/bundle/arguments?attempt=2", headers: runner_headers(run)
    assert_response :success
    assert_equal "12\n--fast\n", response.body, "and its arguments are there for the second runner"
  end

  test "it is never started again more than once" do
    run = start_session(resume_session_id: "old-session")
    post_result run, 1, attempt: 1
    assert run.reload.running?
    post_output run, ndjson(NO_SESSION), offset: 0, attempt: 2
    post_result run, 1, attempt: 2

    assert run.reload.error?
    assert_equal 2, @orca.terminal_commands.size
    assert_equal "error_during_execution", run.error_class
  end

  test "a session that ran, was stopped, or continued nothing is not started again" do
    ran = start_session(resume_session_id: "old-session")
    post_output ran, ndjson(INIT, RESULT.merge(subtype: "error_max_turns", is_error: true, num_turns: 12))
    post_result ran, 1
    assert ran.reload.error?

    killed = start_session(resume_session_id: "old-session")
    post_result killed, 143, signalled: true
    assert killed.reload.error?

    stopped = start_session(resume_session_id: "old-session")
    stopped.update_columns(runner_state: stopped.runner_state.merge("stop_reason" => "canceled"))
    post_result stopped, 1
    assert stopped.reload.canceled?

    fresh = start_session
    post_result fresh, 1
    assert fresh.reload.error?
    assert_equal 4, @orca.terminal_commands.size, "one terminal each"
  end

  test "when starting again fails too, the run is finished as an error" do
    run = start_session(resume_session_id: "old-session")
    @orca.refuse("terminal create")
    post_result run, 1
    assert_response :no_content
    run.reload

    assert run.error?
    assert_match "Continuing the earlier session failed, and so did starting again without it", run.error
    assert_equal [ [ run.id, "error" ] ], @finished
    assert_equal "worktree rm", @orca.commands.last
  end
end
