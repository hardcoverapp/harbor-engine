require "test_helper"

class HarborAgentSessionStreamTest < ActiveSupport::TestCase
  Stream = Harbor::AgentSession::Stream
  Digest = Harbor::AgentSession::Digest
  ResumeFallback = Harbor::AgentSession::ResumeFallback

  def lines(*events) = events.map { |event| JSON.generate(event) }.join("\n")

  INIT = { type: "system", subtype: "init", session_id: "sess-1", model: "claude-sonnet-5-5", permissionMode: "bypassPermissions",
           claude_code_version: "9.9.9", tools: %w[Read Bash], mcp_servers: [], plugins: [], cwd: "/work/x", uuid: "u-1" }.freeze
  RESULT = { type: "result", subtype: "success", is_error: false, total_cost_usd: 0.4321, duration_ms: 45_400, duration_api_ms: 40_000,
             num_turns: 6, result: "All done.", stop_reason: "end_turn", session_id: "sess-1",
             usage: { input_tokens: 2000, output_tokens: 600, cache_read_input_tokens: 9000, cache_creation_input_tokens: 200 } }.freeze

  # --- claude ---

  test "the init event gives the session and the model" do
    stream = Stream.parse(lines(INIT))
    assert_equal "sess-1", stream.summary.session_id
    assert_equal "claude-sonnet-5-5", stream.summary.model
    event = stream.events.sole
    assert_equal [ "system", "init", "session sess-1 · claude-sonnet-5-5" ], [ event.event_type, event.subtype, event.summary ]
    assert_equal %w[claude_code_version mcp_servers model permissionMode plugins session_id tools], event.payload.keys.sort
  end

  test "the result gives the cost, the duration, the four token counts and the final text" do
    summary = Stream.parse(lines(INIT, RESULT)).summary
    assert summary.success?
    assert_equal "success", summary.result_subtype
    assert_equal false, summary.is_error
    assert_equal 0.4321, summary.cost_usd
    assert_equal 45_400, summary.duration_ms
    assert_equal [ 2000, 600, 9000, 200 ],
                 [ summary.input_tokens, summary.output_tokens, summary.cache_read_tokens, summary.cache_creation_tokens ]
    assert_equal "All done.", summary.final_text
    assert_equal [ { "num_turns" => 6, "is_error" => false } ], summary.result_turns
  end

  test "the result event is one line of the timeline, with what it cost" do
    event = Stream.parse(lines(RESULT)).events.sole
    assert_equal [ "result", "success", "success · 45s · $0.4321" ], [ event.event_type, event.subtype, event.summary ]
    assert_equal %w[duration_api_ms duration_ms is_error num_turns stop_reason subtype total_cost_usd usage], event.payload.keys.sort
  end

  test "an error result is not a success, and its subtype says what kind" do
    summary = Stream.parse(lines(INIT, RESULT.merge(subtype: "error_max_turns", is_error: true, result: nil))).summary
    assert_not summary.success?
    assert_equal "error_max_turns", summary.result_subtype
    assert_equal true, summary.is_error
    assert_nil summary.final_text

    bare = Stream.parse(lines(type: "result", is_error: true)).summary
    assert_equal "error", bare.result_subtype, "a result with no subtype is named from is_error"
    assert_equal "success", Stream.parse(lines(type: "result")).summary.result_subtype
    assert_not Stream.parse(lines(RESULT.merge(is_error: true))).summary.success?, "is_error wins over a subtype of success"
  end

  test "assistant turns become one event per text block and per tool use" do
    stream = Stream.parse(lines(
      { type: "assistant", message: { content: [
        { type: "text", text: "  I'll read the file.  " },
        { type: "text", text: "   " },
        { type: "tool_use", id: "t1", name: "Read", input: { file_path: "app/models/book.rb" } },
        { type: "tool_use", id: "t2", name: "Bash", input: { command: "bin/rails   test\n test/x" } },
        { type: "tool_use", id: "t3", name: "Edit", input: { file_path: "a.rb", old_string: "x" } },
        { type: "tool_use", id: "t4", name: "Write", input: { file_path: "b.rb" } },
        { type: "tool_use", id: "t5", name: "Grep", input: { pattern: "def call" } },
        { type: "tool_use", id: "t6", name: "Glob", input: { pattern: "**/*.rb" } },
        { type: "tool_use", id: "t7", name: "WebFetch", input: { url: "https://example.com/docs" } },
        { type: "tool_use", id: "t8", name: "mcp__docs__ask", input: { question: "why?" } },
        { type: "tool_use", id: "t9", name: "Odd", input: "not a hash" } ] } }))

    assert_equal [ "I'll read the file.", "Read app/models/book.rb", "Ran bin/rails test test/x", "Edited a.rb", "Wrote b.rb",
                   "Searched def call", "Globbed **/*.rb", "WebFetch(https://example.com/docs)", "mcp__docs__ask()", "Odd()" ],
                 stream.events.map(&:summary)
    assert_equal [ nil, "Read", "Bash", "Edit", "Write", "Grep", "Glob", "WebFetch", "mcp__docs__ask", "Odd" ], stream.events.map(&:tool_name)
    assert_equal %w[text tool_use], stream.events.map(&:subtype).uniq
    assert_equal({ "id" => "t1", "input" => { "file_path" => "app/models/book.rb" } }, stream.events[1].payload)
    assert_equal({ "text" => "I'll read the file." }, stream.events[0].payload)
  end

  test "an API retry is kept, with what it waited for" do
    event = Stream.parse(lines(type: "system", subtype: "api_retry", attempt: 3, error_status: 529, delay_ms: 4000, uuid: "u")).events.sole
    assert_equal [ "system", "api_retry", "API retry attempt 3 (HTTP 529), waiting 4000ms" ], [ event.event_type, event.subtype, event.summary ]
    assert_not event.payload.key?("uuid")
    assert_equal "API retry attempt 1", Stream.parse(lines(type: "system", subtype: "api_retry", attempt: 1)).events.sole.summary
  end

  test "noise is passed over, and a type nobody has seen is kept raw" do
    stream = Stream.parse(lines(
      { type: "system", subtype: "thinking_tokens", count: 5 },
      { type: "rate_limit_event", info: {} },
      { type: "user", message: { content: [ { type: "tool_result", tool_use_id: "t1", content: "ok" } ] } },
      { type: "system", subtype: "compact_boundary", detail: 1 },
      { type: "brand_new_thing", detail: { a: 1 } },
      { detail: "no type at all" }))

    assert_equal [ %w[system compact_boundary system/compact_boundary], [ "brand_new_thing", nil, "brand_new_thing" ], [ "unknown", nil, "" ] ],
                 stream.events.map { |e| [ e.event_type, e.subtype, e.summary ] }
    assert_equal({ "type" => "brand_new_thing", "detail" => { "a" => 1 } }, stream.events[1].payload)
  end

  test "a line that isn't an event never stops the reading: it is kept as plain output, or dropped if it is a cut-off event" do
    stream = Stream.parse([ JSON.generate(INIT), "Error: could not connect to the API", "", "   ", '{"type":"assistant","message":{"cont',
                            "[1, 2, 3]", "bash: line 3: nope: command not found", JSON.generate(RESULT) ].join("\n"))

    assert_equal %w[init success], stream.events.map(&:subtype)
    assert_equal "Error: could not connect to the API\n[1, 2, 3]\nbash: line 3: nope: command not found", stream.plain_tail
    assert_equal "All done.", stream.summary.final_text
  end

  test "only the end of a long run of plain output is remembered" do
    stream = Stream.new
    3000.times { |i| stream.feed("plain line #{i}") }
    assert_operator stream.plain_tail.length, :<=, Stream::PLAIN_CAP * 2 + 20
    assert stream.plain_tail.end_with?("plain line 2999")
  end

  test "a huge payload is cut down to a preview" do
    event = Stream.parse(lines(type: "assistant", message: { content: [
      { type: "tool_use", id: "t1", name: "Write", input: { file_path: "big.txt", content: "é" * 5000 } } ] })).events.sole
    assert_equal true, event.payload["_truncated"]
    assert_operator event.payload["_preview"].bytesize, :<=, Stream::PAYLOAD_CAP
    assert event.payload["_preview"].valid_encoding?
    assert_equal "Wrote big.txt", event.summary
  end

  test "it can be fed a line at a time, giving each line's events and a summary that fills in" do
    stream = Stream.new
    assert_equal [ "init" ], stream.feed(JSON.generate(INIT)).map(&:subtype)
    assert_equal "sess-1", stream.summary.session_id
    assert_nil stream.summary.cost_usd

    assert_equal [], stream.feed("")
    assert_equal [], stream.feed("not json")
    assert_equal [], stream.feed(JSON.generate(type: "rate_limit_event"))
    two = stream.feed(JSON.generate(type: "assistant", message: { content: [ { type: "text", text: "a" }, { type: "text", text: "b" } ] }) + "\n")
    assert_equal %w[a b], two.map(&:summary)

    assert_equal [ "success" ], stream.feed(JSON.generate(RESULT)).map(&:subtype)
    assert_equal 0.4321, stream.summary.cost_usd
    assert_equal 4, stream.events.size
  end

  # --- subagents: found and returned, never acted on ---

  DELEGATED = [
    { type: "system", subtype: "init", session_id: "sess-1", model: "claude-opus-5" },
    { type: "assistant", message: { content: [
      { type: "tool_use", id: "toolu_docs", name: "mcp__docs__ask", input: { question: "is dark mode a known issue?" } } ] } },
    { type: "assistant", message: { content: [
      { type: "tool_use", id: "toolu_agent1", name: "Agent",
        input: { subagent_type: "researcher", description: "verify dark mode bug", prompt: "Check the app for the dark mode toggle bug" } } ] } },
    { type: "assistant", parent_tool_use_id: "toolu_agent1",
      message: { model: "claude-sonnet-5",
                 usage: { input_tokens: 1000, output_tokens: 200, cache_read_input_tokens: 5000, cache_creation_input_tokens: 100 },
                 content: [ { type: "tool_use", id: "t1", name: "Grep", input: { pattern: "darkMode" } } ] } },
    { type: "assistant", parent_tool_use_id: "toolu_agent1",
      message: { model: "claude-sonnet-5",
                 usage: { input_tokens: 500, output_tokens: 300, cache_read_input_tokens: 0, cache_creation_input_tokens: 0 },
                 content: [ { type: "text", text: "Confirmed at app/components/Theme.tsx:42" } ] } },
    { type: "user", parent_tool_use_id: "toolu_agent1", message: { content: [ { type: "tool_result", tool_use_id: "t1", content: "…" } ] } },
    { type: "user", message: { content: [
      { type: "tool_result", tool_use_id: "toolu_agent1", is_error: false,
        content: [ { type: "text", text: "Confirmed at app/components/Theme.tsx:42" } ] } ] } },
    { type: "result", subtype: "success", is_error: false, total_cost_usd: 0.35, duration_ms: 45_000,
      result: "Yes — confirmed, see Theme.tsx:42.",
      usage: { input_tokens: 2000, output_tokens: 600, cache_read_input_tokens: 9000, cache_creation_input_tokens: 200 } }
  ].freeze

  test "a subagent's work is gathered as a delegation, without polluting the parent's timeline" do
    stream = Stream.parse(lines(*DELEGATED))

    assert_equal 1, stream.delegations.size
    delegation = stream.delegations["toolu_agent1"]
    assert_equal "researcher", delegation.subagent_type
    assert_equal "verify dark mode bug", delegation.description
    assert_equal "claude-sonnet-5", delegation.model
    assert_equal [ 1500, 500, 5000, 100 ],
                 [ delegation.input_tokens, delegation.output_tokens, delegation.cache_read_tokens, delegation.cache_creation_tokens ]
    assert_equal false, delegation.is_error
    assert_match "Theme.tsx:42", delegation.result_text
    assert_equal [ "Searched darkMode", "Confirmed at app/components/Theme.tsx:42" ], delegation.events.map(&:summary)

    parent_tools = stream.events.select { |e| e.subtype == "tool_use" }.map(&:tool_name)
    assert_equal %w[mcp__docs__ask Agent], parent_tools, "the subagent's own tool calls are not the parent's"
    assert_equal 0.35, stream.summary.cost_usd
    assert_equal "Yes — confirmed, see Theme.tsx:42.", stream.summary.final_text
    assert_equal 0, Harbor::Run.where.not(parent_run_id: nil).count, "nothing is recorded: what to do with a delegation is the host's"
  end

  test "a delegation with no description is named from its prompt, and a failed one says so" do
    stream = Stream.parse(lines(
      { type: "assistant", message: { content: [ { type: "tool_use", id: "a1", name: "Task", input: { prompt: "p" * 300 } } ] } },
      { type: "user", message: { content: [ { type: "tool_result", tool_use_id: "a1", is_error: true, content: "it broke" } ] } },
      { type: "assistant", parent_tool_use_id: "never-registered", message: { content: [ { type: "text", text: "orphan" } ] } }))
    delegation = stream.delegations.fetch("a1")
    assert_equal 180, delegation.description.length
    assert_equal [ true, "it broke" ], [ delegation.is_error, delegation.result_text ]
    assert_equal [ "Task" ], stream.events.map(&:tool_name)
  end

  # --- codex ---

  test "codex's result text, session, tools and cache tokens are read the same way" do
    stream = Stream.parse(lines(
      { type: "thread.started", thread_id: "thread-1" },
      { type: "item.completed", item: { type: "command_execution", command: "rg model app" } },
      { type: "item.completed", item: { type: "agent_message", text: "Draft complete." } },
      { type: "turn.completed", usage: { input_tokens: 300, cached_input_tokens: 200, output_tokens: 40 } }))

    assert stream.summary.success?
    assert_equal "thread-1", stream.summary.session_id
    assert_equal "Draft complete.", stream.summary.final_text
    assert_equal 100, stream.summary.input_tokens, "cached input is taken out of input"
    assert_equal 200, stream.summary.cache_read_tokens
    assert_equal 40, stream.summary.output_tokens
    assert_equal "Bash", stream.events.first.tool_name
    assert_equal [ %w[assistant command_execution] + [ "rg model app" ], %w[assistant agent_message] + [ "Draft complete." ] ],
                 stream.events.map { |e| [ e.event_type, e.subtype, e.summary ] }
  end

  test "a codex failure is an error result" do
    %w[turn.failed error].each do |type|
      stream = Stream.parse(lines({ type: "thread.started", thread_id: "t" }, { type: type, message: "quota" }))
      assert_not stream.summary.success?
      assert_equal [ "error", true ], [ stream.summary.result_subtype, stream.summary.is_error ]
      assert_equal [ "result", "error", "Codex failed" ], stream.events.sole.then { |e| [ e.event_type, e.subtype, e.summary ] }
    end
    odd = Stream.parse(lines(type: "item.completed", item: { type: "file_change" }))
    assert_equal "file_change", odd.events.sole.summary
    assert_equal 0, Stream.parse(lines(type: "turn.completed", usage: { input_tokens: 5, cached_input_tokens: 9 })).summary.input_tokens
  end

  # --- the live log's lines ---

  test "each interesting claude event is one readable line" do
    assert_equal "[init] session sess-1 · model claude-sonnet-5-5", Digest.line(JSON.generate(INIT))
    assert_equal "[init] session ? · model ?", Digest.line(JSON.generate(type: "system", subtype: "init"))
    assert_equal "[api retry] attempt 2 (HTTP 529)", Digest.line(JSON.generate(type: "system", subtype: "api_retry", attempt: 2, error_status: 529))
    assert_equal "[api retry] attempt ?", Digest.line(JSON.generate(type: "system", subtype: "api_retry"))
    assert_equal "[result] success · 45s · $0.43", Digest.line(JSON.generate(RESULT))
    assert_equal "[result] ?", Digest.line(JSON.generate(type: "result"))
    assert_equal "[result] error_max_turns · 2s", Digest.line(JSON.generate(type: "result", subtype: "error_max_turns", duration_ms: 1600))

    turn = { type: "assistant", message: { content: [
      { type: "text", text: "  Looking.  " }, { type: "text", text: " " },
      { type: "tool_use", name: "Read", input: { file_path: "app/models/book.rb" } },
      { type: "tool_use", name: "Bash", input: { command: "ls\n  -la" } },
      { type: "tool_use", name: "TodoWrite", input: { todos: [] } },
      { type: "thinking", thinking: "…" } ] } }
    assert_equal "Looking.\n⏺ Read(app/models/book.rb)\n⏺ Bash(ls -la)\n⏺ TodoWrite", Digest.line(JSON.generate(turn))
    long = { type: "assistant", message: { content: [ { type: "tool_use", name: "Bash", input: { command: "x" * 500 } } ] } }
    assert_equal "⏺ Bash(#{'x' * 120})", Digest.line(JSON.generate(long))
  end

  test "each interesting codex event is one readable line" do
    assert_equal "[init] Codex session thread-1", Digest.line(JSON.generate(type: "thread.started", thread_id: "thread-1"))
    assert_equal "rg model app", Digest.line(JSON.generate(type: "item.completed", item: { type: "command_execution", command: "rg model app" }))
    assert_equal "Draft complete.", Digest.line(JSON.generate(type: "item.completed", item: { type: "agent_message", text: "Draft complete." }))
    assert_nil Digest.line(JSON.generate(type: "item.completed", item: { type: "user_message", text: "the prompt" }))
    assert_equal "[result] success", Digest.line(JSON.generate(type: "turn.completed", usage: {}))
    assert_equal "[result] error", Digest.line(JSON.generate(type: "turn.failed"))
    assert_equal "[result] error", Digest.line(JSON.generate(type: "error", message: "x"))
  end

  test "events with nothing to say are skipped, a line that isn't an event is shown as it is, and nothing raises" do
    [ { type: "user", message: {} }, { type: "system", subtype: "thinking_tokens" }, { type: "rate_limit_event" },
      { type: "new_thing" }, { type: "assistant", message: { content: [] } }, { type: "assistant" },
      { type: "assistant", message: { content: "a string" } }, { type: "result", duration_ms: "soon" } ].each do |event|
      assert_nil Digest.line(JSON.generate(event)), event.inspect
    end
    assert_nil Digest.line("")
    assert_nil Digest.line("  \n")
    assert_equal "Error: Invalid API key", Digest.line("Error: Invalid API key\n")
    assert_equal "harbor: the claude command (claude) isn't installed", Digest.line("harbor: the claude command (claude) isn't installed")
    assert_equal '{"type":"assistant","mess', Digest.line('{"type":"assistant","mess'), "a cut-off event is shown rather than lost"
    assert_equal "[1,2]", Digest.line("[1,2]")
  end

  # --- continuing a session that is gone ---

  test "a missing session reported as a zero-turn error result is tried again from the start" do
    text = JSON.generate(type: "result", subtype: "error_during_execution", is_error: true, num_turns: 0, session_id: "7cbb9b7e",
                         errors: [ "No conversation found with session ID: 7cbb9b7e" ])
    assert ResumeFallback.failed?(exit_status: 1, text:)
  end

  test "a non-zero exit with no result at all is tried again" do
    assert ResumeFallback.failed?(exit_status: 1, text: "")
    assert ResumeFallback.failed?(exit_status: 1, text: "Error: session not found\n")
  end

  test "a session that got turns in and then failed is not tried again" do
    text = lines({ type: "system", subtype: "init", session_id: "abc" },
                 { type: "result", subtype: "error_max_turns", is_error: true, num_turns: 12 })
    assert_not ResumeFallback.failed?(exit_status: 1, text:)
  end

  test "a successful session is not tried again" do
    text = JSON.generate(type: "result", subtype: "success", is_error: false, num_turns: 5)
    assert_not ResumeFallback.failed?(exit_status: 0, text:)
    assert_not ResumeFallback.failed?(exit_status: 0, text: "")
  end

  test "a session that was killed is never tried again" do
    assert_not ResumeFallback.failed?(exit_status: 137, text: "")
    assert_not ResumeFallback.failed?(exit_status: 143, text: "")
  end

  test "a cut-off result line counts as a session that ran" do
    assert_not ResumeFallback.failed?(exit_status: 1, text: '{"type":"result","subtype":"succ')
  end
end
