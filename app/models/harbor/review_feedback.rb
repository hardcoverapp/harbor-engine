module Harbor
  # One signal about a review's output: a reaction on a comment, a thread
  # resolved with or without a code change, a review accepted, a blocking
  # result overridden. Rolled up per rule into precision on the dashboard.
  class ReviewFeedback < ApplicationRecord
    self.table_name = "review_feedbacks"

    SIGNALS = %w[useful noise accepted overridden].freeze
    belongs_to :review_round, class_name: "Harbor::ReviewRound"
    validates :signal, inclusion: { in: SIGNALS }

    # { "n-plus-one" => { useful:, noise:, precision: } } for one kind.
    def self.precision_by(kind)
      where(subject_kind: kind).group(:subject_key, :signal).count.each_with_object({}) do |((key, signal), n), acc|
        acc[key] ||= { useful: 0, noise: 0 }
        acc[key][:useful] += n if signal == "useful"
        acc[key][:noise] += n if signal.in?(%w[noise overridden])
      end.transform_values { |h| h.merge(precision: (h[:useful] + h[:noise]).zero? ? nil : (100.0 * h[:useful] / (h[:useful] + h[:noise])).round) }
    end
  end
end
