module Harbor
  module AgentSession
    # One readable line per interesting event of an agent's stream, for the
    # run's live log: a tool call as it happens instead of a silent wait. The
    # full record is the raw stream; this only has to be legible, and never
    # raises on an event shape it doesn't know.
    module Digest
      TOOL_ARGUMENTS = %w[file_path path command pattern query url description].freeze

      module_function

      # What to show for one line of output, or nil for nothing. A line that
      # isn't a JSON event is the CLI's own stderr or a message from the
      # shell, and is shown as it is.
      def line(text)
        text = text.to_s.chomp
        return nil if text.strip.empty?

        event = parse(text)
        event ? event(event) : text
      end

      # A stream line as an event, or nil when it isn't one.
      def parse(text)
        return nil unless text.lstrip.start_with?("{")
        parsed = JSON.parse(text)
        parsed if parsed.is_a?(Hash)
      rescue JSON::ParserError
        nil
      end

      def event(ev)
        case ev["type"]
        when "thread.started" then "[init] Codex session #{ev['thread_id']}"
        when "item.completed"
          item = ev["item"] || {}
          item["type"] == "user_message" ? nil : (item["text"].presence || item["command"].presence)
        when "turn.completed" then "[result] success"
        when "turn.failed", "error" then "[result] error"
        when "system" then system_event(ev)
        when "assistant"
          Array(ev.dig("message", "content")).filter_map { |block| block(block) }.join("\n").presence
        when "result"
          duration = ev["duration_ms"] && " · #{(ev['duration_ms'] / 1000.0).round}s"
          cost = ev["total_cost_usd"] && format(" · $%.2f", ev["total_cost_usd"])
          "[result] #{ev['subtype'] || '?'}#{duration}#{cost}"
        end
      rescue StandardError
        nil
      end

      def system_event(ev)
        case ev["subtype"]
        when "init" then "[init] session #{ev['session_id'] || '?'} · model #{ev['model'] || '?'}"
        when "api_retry"
          # These explain a slow run, so they are always shown.
          status = ev["error_status"] ? " (HTTP #{ev['error_status']})" : ""
          "[api retry] attempt #{ev['attempt'] || '?'}#{status}"
        end
      end

      def block(block)
        if block["type"] == "tool_use"
          argument = tool_arg(block["input"])
          "⏺ #{block['name']}#{"(#{argument})" if argument.present?}"
        elsif block["type"] == "text" && block["text"].to_s.strip.present?
          block["text"].strip
        end
      end

      # The one argument that says what a tool call was about.
      def tool_arg(input)
        return "" unless input.is_a?(Hash)
        input.values_at(*TOOL_ARGUMENTS).compact.first.to_s.gsub(/\s+/, " ")[0, 120]
      end
    end
  end
end
