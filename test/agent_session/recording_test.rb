require "test_helper"

# What the runner endpoints do for an agent session: output as it arrives,
# and the files the runner fetches.
class HarborAgentSessionRecordingTest < ActionDispatch::IntegrationTest
  include HarborAgentSessions

  INIT = { type: "system", subtype: "init", session_id: "sess-1", model: "claude-sonnet-5-5" }.freeze
  READ = { type: "assistant", message: { content: [ { type: "text", text: "Reading the café menu." },
                                                    { type: "tool_use", id: "t1", name: "Read", input: { file_path: "menu.md" } } ] } }.freeze
  RESULT = { type: "result", subtype: "success", is_error: false, total_cost_usd: 0.25, duration_ms: 3000, num_turns: 2, result: "Done." }.freeze

  setup { @run = start_session }

  def events = @run.run_events.ordered.map { |event| [ event.seq, event.event_type, event.subtype, event.summary ] }

  # The log's lines after Harbor's own opening ones.
  def digested = live_log(@run).lines(chomp: true).drop_while { |line| !line.start_with?("[harbor]") }.drop(1)

  test "the raw stream gets the exact bytes, beside the live log" do
    stream = ndjson(INIT, READ).b
    post_output @run, stream.byteslice(0, 40)
    assert_response :no_content
    post_output @run, stream.byteslice(40, stream.bytesize)

    assert_equal "writer-fix/run-#{@run.id}.ndjson", @run.reload.raw_log_path
    assert_equal "writer-fix/run-#{@run.id}.log", @run.live_log_path
    assert_equal stream, raw_stream(@run)
    assert_equal stream.bytesize, @run.runner_state["received"]
    assert_equal stream.bytesize, @run.runner_state["digested"]
  end

  test "a character split across two posts is whole in the raw stream, in the log and in the events" do
    stream = ndjson(READ).b
    cut = stream.index("\xC3".b) + 1 # between the two bytes of é
    post_output @run, stream.byteslice(0, cut)
    post_output @run, stream.byteslice(cut, stream.bytesize)

    assert_equal stream, raw_stream(@run)
    assert_equal [ "Reading the café menu.", "⏺ Read(menu.md)" ], digested
    assert_equal [ [ 1, "assistant", "text", "Reading the café menu." ], [ 2, "assistant", "tool_use", "Read menu.md" ] ], events
  end

  test "each complete line is digested into the live log once, and a partial line waits for the rest" do
    init, read = ndjson(INIT), ndjson(READ)
    post_output @run, init + read.byteslice(0, 30)
    assert_equal [ "[init] session sess-1 · model claude-sonnet-5-5" ], digested
    assert_equal [ [ 1, "system", "init", "session sess-1 · claude-sonnet-5-5" ] ], events
    assert_equal init.bytesize, @run.reload.runner_state["digested"]
    assert_equal init.bytesize + 30, @run.runner_state["received"]

    post_output @run, read.byteslice(30, 20)
    assert_equal 1, digested.size, "still no newline: nothing more is shown"

    post_output @run, read.byteslice(50, read.bytesize)
    assert_equal [ "[init] session sess-1 · model claude-sonnet-5-5", "Reading the café menu.", "⏺ Read(menu.md)" ], digested
    assert_equal [ 1, 2, 3 ], events.map(&:first)
    assert_equal 3, @run.reload.runner_state["seq"]
  end

  test "events are added to the ones already there, never rebuilt" do
    post_output @run, ndjson(INIT)
    first = @run.run_events.sole
    post_output @run, ndjson(READ)
    post_output @run, ndjson(RESULT)

    assert_equal first.attributes, @run.run_events.find_by(seq: 1).attributes, "the first event is the same row, untouched"
    assert_equal [ [ 1, "init" ], [ 2, "text" ], [ 3, "tool_use" ], [ 4, "success" ] ], @run.run_events.ordered.pluck(:seq, :subtype)
  end

  test "a post that is repeated, or overlaps, adds nothing twice" do
    stream = ndjson(INIT, READ)
    post_output @run, stream, offset: 0
    post_output @run, stream, offset: 0
    assert_response :no_content
    post_output @run, stream.byteslice(10, stream.bytesize) + ndjson(RESULT), offset: 10

    assert_equal stream + ndjson(RESULT), raw_stream(@run)
    assert_equal [ "[init] session sess-1 · model claude-sonnet-5-5", "Reading the café menu.", "⏺ Read(menu.md)", "[result] success · 3s · $0.25" ], digested
    assert_equal 4, @run.run_events.count
  end

  test "a post that leaves a gap is refused with Harbor's count" do
    post_output @run, ndjson(INIT), offset: 0
    post_output @run, ndjson(RESULT), offset: 500
    assert_response :conflict
    assert_equal ndjson(INIT).bytesize.to_s, response.body
    assert_equal ndjson(INIT), raw_stream(@run)
    assert_equal 1, @run.run_events.count
  end

  test "output that isn't an event is shown as it is, and bytes that aren't text are kept raw and made readable only in the log" do
    post_output @run, "Error: Invalid API key \xFF\xFE\n\n".b
    assert_equal "Error: Invalid API key \xFF\xFE\n\n".b, raw_stream(@run)
    assert_equal [ "Error: Invalid API key ??" ], digested
    assert_equal 0, @run.run_events.count
  end

  test "hearing from the runner is noted, and the session id is known as soon as the stream says it" do
    assert_nil @run.runner_state["last_seen_at"]
    travel_to Time.zone.parse("2026-11-12 10:00:00") do
      post_output @run, ndjson(INIT)
    end
    assert_equal Time.zone.parse("2026-11-12 10:00:00"), Time.zone.parse(@run.reload.runner_state["last_seen_at"])
    assert_equal "sess-1", @run.session_id
    assert @run.running?
  end

  test "a finished session takes no more output" do
    Harbor::AgentSession.stop!(@run)
    post_output @run, ndjson(INIT), offset: 0
    assert_response :conflict
    assert_equal "finished", response.body
    assert_equal 0, @run.run_events.count
  end

  # --- the run's files ---

  def fetch(name, run: @run, attempt: nil)
    post "/harbor/runner/runs/#{run.id}/bundle/#{name}#{"?attempt=#{attempt}" if attempt}",
         headers: { "Authorization" => "Bearer #{Harbor::RunToken.generate(run)}" }
    response.body
  end

  test "the runner fetches the prompt, the system prompt and the MCP config" do
    assert_equal "Fix the test.", fetch("prompt")
    assert_response :success
    assert_equal "text/plain", response.media_type
    assert_equal "no-store", response.headers["Cache-Control"]
    assert_match(/\AYou write\.\n\nThis is an unattended run/, fetch("system"))
    assert_equal({ "mcpServers" => {} }, JSON.parse(fetch("mcp")), "with no servers given, an empty config of its own")
    assert_equal "application/json", response.media_type

    with_servers = start_session(mcp_config: { mcpServers: { docs: { command: "node", args: [ "docs.js" ] } } })
    assert_equal({ "mcpServers" => { "docs" => { "command" => "node", "args" => [ "docs.js" ] } } }, JSON.parse(fetch("mcp", run: with_servers)))
  end

  test "only the run's own files can be asked for, with its own token" do
    %w[passwd Prompt env.bak ..%2Fenv].each do |name|
      fetch(name)
      assert_response :not_found, name
    end
    post "/harbor/runner/runs/#{@run.id}/bundle/env"
    assert_response :unauthorized
    post "/harbor/runner/runs/#{@run.id}/bundle/env", headers: { "Authorization" => "Bearer #{Harbor::RunToken.generate(new_run)}" }
    assert_response :unauthorized
  end

  test "the environment is worked out from the host's hook each time it is asked for, and kept nowhere" do
    asked = []
    Harbor.config.agent_session_env = lambda do |run, provider|
      asked << [ run.id, provider ]
      { "CLAUDE_CODE_OAUTH_TOKEN" => "oauth-s3cr3t-#{asked.size}", "GH_TOKEN" => "gh-s3cr3t" }
    end

    assert_equal "unset ANTHROPIC_API_KEY\nexport CLAUDE_CODE_OAUTH_TOKEN='oauth-s3cr3t-1'\nexport GH_TOKEN='gh-s3cr3t'\n", fetch("env")
    assert_match "oauth-s3cr3t-2", fetch("env")
    assert_equal [ [ @run.id, "anthropic" ] ] * 2, asked

    assert_no_match(/s3cr3t/, @run.reload.attributes.to_json, "no column of the run holds it")
    assert_no_match(/s3cr3t/, live_log(@run))
    assert_no_match(/s3cr3t/, @orca.calls.to_json, "and it was on no command line")
  end

  test "an environment the hook got wrong is refused, by name, and said in the log" do
    Harbor.config.agent_session_env = ->(*) { { "BAD NAME" => "the-s3cr3t" } }
    body = fetch("env")
    assert_response :unprocessable_entity
    assert_match '"BAD NAME" is not a valid environment variable name', body
    assert_match "the session's environment was refused", live_log(@run)
    assert_no_match(/s3cr3t/, body + live_log(@run))
  end

  test "files are only given out while the session is running" do
    Harbor.config.agent_session_env = ->(*) { { "GH_TOKEN" => "gh-s3cr3t" } }
    Harbor::AgentSession.stop!(@run)
    %w[prompt system mcp env].each do |name|
      body = fetch(name)
      assert_response :conflict, name
      assert_equal "finished", body
    end

    waiting = new_run
    fetch("prompt", run: waiting)
    assert_response :not_found, "a run that was never started as a session has none"
  end

  test "a post from an earlier start of the run is refused" do
    @run.update_columns(runner_state: @run.runner_state.merge("attempt" => 2))
    post_output @run, ndjson(INIT), offset: 0, attempt: 1
    assert_response :conflict
    assert_equal "stale", response.body
    fetch("prompt", attempt: 1)
    assert_response :conflict
    post_result @run, 0, attempt: 1
    assert_response :no_content
    assert @run.reload.running?, "and its result changes nothing"

    post_output @run, ndjson(INIT), offset: 0, attempt: 2
    assert_response :no_content
    assert_equal "Fix the test.", fetch("prompt", attempt: 2)
  end
end
