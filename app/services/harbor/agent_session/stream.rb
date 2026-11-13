module Harbor
  module AgentSession
    # Reads an agent CLI's event stream: the NDJSON `claude -p --output-format
    # stream-json --verbose` and `codex exec --json` print. It is fed one line
    # at a time and keeps a running summary (session, model, cost, the four
    # token counts, the final text), so it works on output as it arrives as
    # well as on a whole file:
    #
    #   stream = Stream.new
    #   stream.feed(line)   # => the events that line produced
    #   stream.summary      # what is known so far
    #
    #   Stream.parse(ndjson)   # a whole stream at once
    #
    # It never raises on an event it doesn't recognise: the CLIs add types
    # over time, so an unknown type is kept raw and a line that isn't JSON is
    # remembered as plain output. The four token counts stay separate: cache
    # reads cost a fraction of fresh input, and summing them would make cheap
    # runs look expensive.
    #
    # Subagents an agent spawned are returned as data (`delegations`). What a
    # site does with them, such as recording each as a run of its own, is the
    # site's.
    class Stream
      # Types that fire many times a run and carry nothing a timeline needs.
      # Not "unknown": unknown types are kept.
      IGNORED = [
        %w[system thinking_tokens],
        [ "rate_limit_event", nil ],
        [ "user", nil ] # tool results echo back as user turns; the tool_use event covers them
      ].freeze

      # Characters of JSON kept per event; the raw stream has the full record.
      PAYLOAD_CAP = 2_000
      # Characters of plain (non-JSON) output remembered, newest last.
      PLAIN_CAP = 2_000

      Summary = Struct.new(:session_id, :model, :cost_usd, :duration_ms, :input_tokens, :output_tokens,
                           :cache_read_tokens, :cache_creation_tokens, :result_subtype, :is_error,
                           :final_text, :result_turns, keyword_init: true) do
        def success? = result_subtype == "success" && !is_error
      end

      Event = Struct.new(:event_type, :subtype, :tool_name, :summary, :payload, keyword_init: true)

      # One subagent spawned inside the session. Events that carry its tool
      # use id as their parent belong to it, not to the main timeline. Its
      # token counts are summed over its turns: each turn is a billed call.
      Delegation = Struct.new(:tool_use_id, :subagent_type, :description, :model, :input_tokens, :output_tokens,
                              :cache_read_tokens, :cache_creation_tokens, :result_text, :is_error, :events,
                              keyword_init: true)

      # The names the CLI has given its subagent tool across versions.
      AGENT_TOOL_NAMES = %w[Agent Task].freeze

      TOOL_VERBS = { "Edit" => "Edited", "Write" => "Wrote", "Read" => "Read", "Bash" => "Ran",
                     "Grep" => "Searched", "Glob" => "Globbed" }.freeze

      attr_reader :summary, :events, :delegations

      def self.parse(ndjson)
        new.tap { |stream| ndjson.to_s.each_line { |line| stream.feed(line) } }
      end

      def initialize
        @summary = Summary.new(result_turns: [])
        @events = []
        @delegations = {}
        @plain = +""
      end

      # Takes one line of output and returns the events it produced (often
      # none). They are also added to `events`.
      def feed(line)
        line = line.to_s.strip
        return [] if line.empty?

        before = @events.size
        if line.start_with?("{")
          # A line cut short by a kill is dropped: what came before it stands.
          event = parse_line(line)
          ingest(event) if event
        else
          plain(line)
        end
        @events[before..]
      end

      # The end of what the command printed that wasn't an event: the CLI's
      # stderr, a shell error. Where a failure explains itself.
      def plain_tail = @plain.strip

      private

      def parse_line(line)
        parsed = JSON.parse(line)
        parsed if parsed.is_a?(Hash)
      rescue JSON::ParserError
        # A result cut short (the process was killed mid-line) still shows
        # the agent got as far as a result.
        @summary.result_turns << { "num_turns" => 1 } if line.match?(/"type"\s*:\s*"result"/)
        nil
      end

      def plain(line)
        @plain << line << "\n"
        @plain = @plain.last(PLAIN_CAP) if @plain.length > PLAIN_CAP * 2
      end

      def ingest(ev)
        type = ev["type"].to_s
        subtype = ev["subtype"].presence

        # Events from inside a subagent belong to its delegation.
        if ev["parent_tool_use_id"].present?
          ingest_subagent(ev) if type == "assistant"
          return
        end

        # A subagent's result comes back as a user tool_result turn: take it
        # before the type is passed over.
        capture_delegation_results(ev) if type == "user"

        return if IGNORED.any? { |t, s| t == type && (s.nil? || s == subtype) }

        case [ type, subtype ]
        in [ "thread.started", _ ]
          @summary.session_id = ev["thread_id"]
        in [ "item.completed", _ ]
          item = ev["item"].is_a?(Hash) ? ev["item"] : {}
          @summary.final_text = item["text"] if item["type"] == "agent_message"
          @events << Event.new(event_type: "assistant", subtype: item["type"],
                               tool_name: item["type"] == "command_execution" ? "Bash" : nil,
                               summary: (item["text"].presence || item["command"].presence || item["type"]).to_s.truncate(255),
                               payload: cap(item))
        in [ "turn.completed", _ ]
          usage = ev["usage"] || {}
          # codex counts cached input inside input; the columns keep them apart.
          @summary.input_tokens = usage["input_tokens"] && [ usage["input_tokens"].to_i - usage["cached_input_tokens"].to_i, 0 ].max
          @summary.output_tokens = usage["output_tokens"]
          @summary.cache_read_tokens = usage["cached_input_tokens"]
          @summary.result_subtype = "success"
          @summary.is_error = false
        in [ "turn.failed", _ ] | [ "error", _ ]
          @summary.result_subtype = "error"
          @summary.is_error = true
          @events << Event.new(event_type: "result", subtype: "error", summary: "Codex failed", payload: cap(ev))
        in [ "system", "init" ]
          @summary.session_id = ev["session_id"]
          @summary.model = ev["model"]
          @events << Event.new(event_type: "system", subtype: "init",
                               summary: "session #{ev['session_id']} · #{ev['model']}",
                               payload: cap(ev.slice("session_id", "model", "permissionMode", "claude_code_version",
                                                     "tools", "mcp_servers", "plugins")))
        in [ "system", "api_retry" ]
          # These explain slow runs, so they are always kept.
          @events << Event.new(event_type: "system", subtype: "api_retry",
                               summary: "API retry attempt #{ev['attempt']}#{" (HTTP #{ev['error_status']})" if ev['error_status']}" \
                                        "#{", waiting #{ev['delay_ms']}ms" if ev['delay_ms']}",
                               payload: cap(ev.except("type", "uuid")))
        in [ "assistant", _ ]
          ingest_assistant(ev)
        in [ "result", _ ]
          ingest_result(ev, subtype)
        else
          @events << Event.new(event_type: type.presence || "unknown", subtype: subtype,
                               summary: "#{type}#{"/#{subtype}" if subtype}", payload: cap(ev))
        end
      end

      # One event per text block and per tool use.
      def ingest_assistant(ev)
        Array(ev.dig("message", "content")).each do |block|
          next unless block.is_a?(Hash)
          register_delegation(block) if block["type"] == "tool_use" && AGENT_TOOL_NAMES.include?(block["name"])
          event = block_event(block, payload_id: true)
          @events << event if event
        end
      end

      def block_event(block, payload_id: false)
        case block["type"]
        when "tool_use"
          payload = payload_id ? { "id" => block["id"], "input" => block["input"] } : { "input" => block["input"] }
          Event.new(event_type: "assistant", subtype: "tool_use", tool_name: block["name"],
                    summary: tool_summary(block["name"], block["input"]), payload: cap(payload))
        when "text"
          text = block["text"].to_s.strip
          return nil if text.empty?
          Event.new(event_type: "assistant", subtype: "text", summary: text.truncate(255), payload: cap({ "text" => text }))
        end
      end

      def register_delegation(block)
        input = block["input"].is_a?(Hash) ? block["input"] : {}
        @delegations[block["id"]] = Delegation.new(
          tool_use_id: block["id"], subagent_type: input["subagent_type"],
          description: input["description"].presence || input["prompt"].to_s.truncate(180),
          input_tokens: 0, output_tokens: 0, cache_read_tokens: 0, cache_creation_tokens: 0, events: [])
      end

      def ingest_subagent(ev)
        delegation = @delegations[ev["parent_tool_use_id"]]
        return unless delegation

        delegation.model ||= ev.dig("message", "model")
        if (usage = ev.dig("message", "usage")).is_a?(Hash)
          delegation.input_tokens += usage["input_tokens"].to_i
          delegation.output_tokens += usage["output_tokens"].to_i
          delegation.cache_read_tokens += usage["cache_read_input_tokens"].to_i
          delegation.cache_creation_tokens += usage["cache_creation_input_tokens"].to_i
        end

        Array(ev.dig("message", "content")).each do |block|
          event = block.is_a?(Hash) ? block_event(block) : nil
          delegation.events << event if event
        end
      end

      def capture_delegation_results(ev)
        Array(ev.dig("message", "content")).each do |block|
          next unless block.is_a?(Hash) && block["type"] == "tool_result"
          delegation = @delegations[block["tool_use_id"]]
          next unless delegation
          delegation.is_error = block["is_error"] == true
          delegation.result_text = tool_result_text(block["content"])
        end
      end

      def tool_result_text(content)
        case content
        when String then content
        when Array then content.filter_map { |c| c["text"] if c.is_a?(Hash) && c["type"] == "text" }.join("\n")
        end
      end

      def ingest_result(ev, subtype)
        usage = ev["usage"] || {}
        @summary.result_subtype = subtype || (ev["is_error"] ? "error" : "success")
        @summary.is_error = ev["is_error"] == true
        @summary.cost_usd = ev["total_cost_usd"]
        @summary.duration_ms = ev["duration_ms"]
        @summary.input_tokens = usage["input_tokens"]
        @summary.output_tokens = usage["output_tokens"]
        @summary.cache_read_tokens = usage["cache_read_input_tokens"]
        @summary.cache_creation_tokens = usage["cache_creation_input_tokens"]
        @summary.final_text = ev["result"].presence
        @summary.result_turns << ev.slice("num_turns", "is_error")
        @events << Event.new(
          event_type: "result", subtype: @summary.result_subtype,
          summary: "#{@summary.result_subtype} · #{(ev['duration_ms'].to_i / 1000.0).round}s · $#{format('%.4f', ev['total_cost_usd'].to_f)}",
          payload: cap(ev.slice("subtype", "is_error", "duration_ms", "duration_api_ms", "num_turns", "total_cost_usd", "usage", "stop_reason")))
      end

      # A short human line: "Edited app/models/book.rb".
      def tool_summary(name, input)
        input = {} unless input.is_a?(Hash)
        argument = input["file_path"] || input["path"] || input["command"] || input["pattern"] ||
                   input["query"] || input["url"] || input["description"] || input["prompt"]
        argument = argument.to_s.squish.truncate(180)
        verb = TOOL_VERBS[name]
        verb ? "#{verb} #{argument}" : "#{name}(#{argument})"
      end

      # A giant tool input must not bloat the events table.
      def cap(hash)
        json = hash.to_json
        return hash if json.bytesize <= PAYLOAD_CAP
        # A character cut in half at the cap is dropped, not replaced.
        { "_truncated" => true, "_preview" => json.byteslice(0, PAYLOAD_CAP).scrub("") }
      end
    end
  end
end
