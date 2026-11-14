module Harbor
  # A bug that got through a review, linked to the round that approved it.
  class ReviewEscape < ApplicationRecord
    self.table_name = "review_escapes"

    SOURCES = %w[regressed_in deploy_errors bugsnag].freeze
    belongs_to :review_round, class_name: "Harbor::ReviewRound", optional: true
    validates :source, inclusion: { in: SOURCES }
  end
end
