module Harbor
  module ConductorCloud
    # Turns a Conductor session's transcript messages into the stream an agent
    # command prints: one JSON event to a line, which is what
    # Harbor::AgentSession's recorder and stream reader take.
    #
    # A message's `content.rawPayload` is the agent's own event. For claude
    # that is its stream-json, passed through untouched. Conductor's codex
    # transcript wraps each event as {"event": {...}, "thread_id": ...} and
    # names item types in camelCase; those are unwrapped into the shape
    # `codex exec --json` prints.
    module Transcript
      CODEX_ITEM_TYPES = {
        "agentMessage" => "agent_message", "commandExecution" => "command_execution",
        "userMessage" => "user_message", "fileChange" => "file_change", "mcpToolCall" => "mcp_tool_call",
        "webSearch" => "web_search", "todoList" => "todo_list"
      }.freeze
      # How much of an agent's last words is kept as the reason a run failed.
      TEXT_CAP = 1_000

      # What a page of messages came to: the stream's bytes, how the agent's
      # turn ended if it did ("ok", or "failed" with what it said), and the
      # last thing the agent said.
      Read = Struct.new(:bytes, :ended, :error, :last_text, keyword_init: true)

      module_function

      def normalize(payload)
        return payload unless payload.is_a?(Hash) && payload["type"].nil? && payload["event"].is_a?(Hash)
        event = payload["event"]
        item = event["item"]
        return event unless item.is_a?(Hash) && CODEX_ITEM_TYPES.key?(item["type"])
        event.merge("item" => item.merge("type" => CODEX_ITEM_TYPES[item["type"]]))
      end

      # Only the agent's own events are the stream: the prompt as Conductor
      # echoes it, and anything else, is passed over.
      def read(messages)
        read = Read.new(bytes: +"")
        Array(messages).each do |message|
          next unless message.is_a?(Hash) && message["type"] == "agent"
          payload = normalize(message.dig("content", "rawPayload"))
          next unless payload.is_a?(Hash)

          read.bytes << JSON.generate(payload) << "\n"
          case payload["type"]
          when "result"
            ok = payload["subtype"] == "success" && payload["is_error"] != true
            read.ended = ok ? "ok" : "failed"
            read.error = ok ? nil : payload["result"].to_s.strip.presence&.truncate(TEXT_CAP)
          when "turn.completed" then read.ended, read.error = "ok", nil
          when "turn.failed", "error"
            read.ended = "failed"
            read.error = (payload.dig("error", "message") || payload["message"]).to_s.strip.presence&.truncate(TEXT_CAP)
          when "item.completed"
            read.last_text = payload.dig("item", "text") if payload.dig("item", "type") == "agent_message"
          when "assistant"
            text = Array(payload.dig("message", "content")).filter_map { |block| block["text"] if block.is_a?(Hash) && block["type"] == "text" }.join("\n")
            read.last_text = text if text.strip.present? && payload["parent_tool_use_id"].blank?
          end
        end
        read.last_text = read.last_text.to_s.strip.presence&.truncate(TEXT_CAP)
        read
      end
    end
  end
end
