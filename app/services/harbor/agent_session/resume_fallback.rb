module Harbor
  module AgentSession
    # Did an attempt that continued an earlier session (`claude --resume <id>`)
    # fail the way a stale or missing session fails, so that it is worth one
    # more attempt without --resume?
    #
    # Yes when the agent never got a turn in: it exited non-zero with no
    # result at all (older CLIs), or it reported an error result with zero
    # turns (current CLIs print a result with "num_turns":0 and "No
    # conversation found with session ID" and exit 1). No when it was killed
    # (137, 143: a stop or a timeout, so no more budget is spent) or really
    # ran and failed part-way (some result with turns).
    module ResumeFallback
      KILLED = [ 137, 143 ].freeze

      module_function

      # `turns` are the stream's result events (Stream::Summary#result_turns);
      # `text` is read for them when they aren't given.
      def failed?(exit_status:, turns: nil, text: nil)
        code = exit_status.to_i
        return false if KILLED.include?(code)

        turns ||= Stream.parse(text).summary.result_turns
        return false if turns.any? { |turn| turn["num_turns"].to_i.positive? }
        return true if turns.any? { |turn| turn["is_error"] == true }
        code != 0 && turns.empty?
      end
    end
  end
end
