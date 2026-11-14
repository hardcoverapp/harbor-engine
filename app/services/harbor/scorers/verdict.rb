module Harbor
  module Scorers
    # Pull the judge's answer out of its final text: the last fenced JSON block
    # (or bare object) with a classification, matched against the scorer's
    # labels. Nil when there is no usable verdict.
    module Verdict
      FENCED = /```(?:json)?\s*(\{.*?\})\s*```/m
      BARE   = /(\{[^{}]*"classification"[^{}]*\})/m

      Result = Struct.new(:classification, :reasoning, :judge_score, keyword_init: true)

      module_function

      def parse(text, labels:)
        candidates = text.to_s.scan(FENCED).flatten + text.to_s.scan(BARE).flatten
        candidates.reverse_each do |json|
          data = JSON.parse(json) rescue next
          next unless data.is_a?(Hash) && data["classification"].present?
          label = labels.find { |l| l.casecmp?(data["classification"].to_s.strip) }
          next unless label
          return Result.new(classification: label, reasoning: data["reasoning"].to_s.strip.presence,
                            judge_score: (Float(data["score"]) rescue nil))
        end
        nil
      end
    end
  end
end
