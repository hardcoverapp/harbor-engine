module Harbor
  # One execution of one step in one scope. Steps inside a loop get a scope per
  # pass ("rounds[2]/"), so replaying the definition always finds the same row.
  class WorkflowStepRun < ApplicationRecord
    self.table_name = "workflow_step_runs"

    STATUSES = %w[running waiting ok error skipped canceled].freeze
    PENDING = %w[running waiting].freeze

    belongs_to :workflow_run, class_name: Harbor.class_name_for(:workflow_run_class)
    belongs_to :run, class_name: Harbor.class_name_for(:run_class), optional: true
    has_many :waits, class_name: "Harbor::WorkflowWait", foreign_key: :workflow_step_run_id, dependent: :delete_all,
                     inverse_of: :workflow_step_run

    validates :status, inclusion: { in: STATUSES }

    scope :pending, -> { where(status: PENDING) }

    def pending? = PENDING.include?(status)
    def finished? = !pending?
    def ok? = status == "ok"
    def failed? = %w[error canceled].include?(status)

    def finish!(status:, output: nil, error: nil)
      update!(status:, output: output.nil? ? self.output : output, error:, ended_at: Time.current)
    end
  end
end
