module Harbor
  module Proposals
    # A drafting run's answer: the last fenced JSON block holding a
    # "proposals" list (which may be empty), each entry naming a known target.
    # Nil when there is no such block.
    #
    #   {"pattern": "<the shared cause>",
    #    "proposals": [
    #      {"target": "agent_prompt", "summary": "<one line>", "after": "<full new system prompt>"},
    #      {"target": "agent_document", "path": "<document path>", "summary": "<one line>", "after": "<full new body>"}
    #    ]}
    module Verdict
      FENCED = /```(?:json)?\s*(\{.*?\})\s*```/m

      Result = Struct.new(:pattern, :proposals, keyword_init: true)

      module_function

      def parse(text)
        text.to_s.scan(FENCED).flatten.reverse_each do |json|
          data = JSON.parse(json) rescue next
          next unless data.is_a?(Hash) && data["proposals"].is_a?(Array)
          proposals = data["proposals"].select { |p| p.is_a?(Hash) && Harbor::Proposals.target_kinds.include?(p["target"].to_s) }
          return Result.new(pattern: data["pattern"].to_s.strip.presence, proposals:)
        end
        nil
      end
    end
  end
end
