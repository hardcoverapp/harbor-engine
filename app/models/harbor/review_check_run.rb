module Harbor
  # One check in one review round: its status, outputs and routing, the run
  # that did the work, and (when reused) the earlier check run whose result
  # stands.
  class ReviewCheckRun < ApplicationRecord
    self.table_name = "review_check_runs"

    STATUSES = %w[queued running passed failed errored skipped reused cancelled].freeze
    DONE     = %w[passed failed errored skipped reused cancelled].freeze

    belongs_to :review_round, class_name: "Harbor::ReviewRound"
    belongs_to :review_rule, class_name: Harbor.class_name_for(:review_rule_class)
    belongs_to :run, class_name: Harbor.class_name_for(:run_class), optional: true
    belongs_to :reused_from, class_name: "Harbor::ReviewCheckRun", optional: true

    validates :status, inclusion: { in: STATUSES }

    scope :evidence, -> { where(stage: "evidence") }
    scope :live, -> { where(mode: "live") }

    def done? = DONE.include?(status)
    def blocking? = gate == "blocking"
    def shadow? = mode == "shadow"
    def definition = review_rule.versions.find_by(number: check_version)&.definition || review_rule.definition

    # passed for gate purposes: a reused result is whatever it reused.
    def effective_status = status == "reused" ? (reused_from&.effective_status || "passed") : status

    def finish!(status:, summary: nil, outputs: nil, artifacts: nil, details: nil, routed: nil)
      update!(status:, summary: summary || self.summary, outputs: outputs || self.outputs,
              artifacts: artifacts || self.artifacts, details: details || self.details,
              routed: routed || self.routed, finished_at: Time.current)
    end
  end
end
