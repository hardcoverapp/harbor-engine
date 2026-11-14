module Harbor
  # One firing of a workflow. It lives as long as the flow does (minutes for
  # a review, days for "get this change merged"), so it is its own record and
  # not a Run; every step that does work IS a Run (runs.workflow_run_id).
  #
  # A run may be about something: a pull request or an issue of a repository
  # (`github_repo`, `pr_number`, `issue_number`), given when it is started. A
  # host says where that lives by overriding `subject_url` in a subclass
  # named by `config.workflow_run_class`.
  class WorkflowRun < ApplicationRecord
    self.table_name = "workflow_runs"

    STATUSES = %w[queued running waiting succeeded failed canceled].freeze
    ACTIVE = %w[queued running waiting].freeze

    belongs_to :workflow, class_name: Harbor.class_name_for(:workflow_class)
    belongs_to :workflow_version, class_name: "Harbor::WorkflowVersion"
    belongs_to :webhook_event, class_name: Harbor.class_name_for(:webhook_event_class), optional: true
    belongs_to :parent_workflow_run, class_name: Harbor.class_name_for(:workflow_run_class), optional: true
    has_many :child_workflow_runs, class_name: Harbor.class_name_for(:workflow_run_class), foreign_key: :parent_workflow_run_id,
                                   dependent: :nullify, inverse_of: :parent_workflow_run
    has_many :step_runs, -> { order(:id) }, class_name: "Harbor::WorkflowStepRun", foreign_key: :workflow_run_id,
                                            dependent: :destroy, inverse_of: :workflow_run
    has_many :waits, class_name: "Harbor::WorkflowWait", foreign_key: :workflow_run_id, dependent: :delete_all, inverse_of: :workflow_run
    has_many :runs, class_name: Harbor.class_name_for(:run_class), foreign_key: :workflow_run_id, dependent: :nullify,
                    inverse_of: :workflow_run
    # Who started it by hand, when the host has told Harbor its user class.
    if Harbor.config.user_class
      belongs_to :triggered_by_user, class_name: Harbor.class_name_for(:user_class), optional: true
    end

    validates :status, inclusion: { in: STATUSES }

    scope :active, -> { where(status: ACTIVE) }
    scope :recent, -> { order(id: :desc) }

    # The newest `per` finished runs of each of these workflows, by workflow id,
    # newest first, with one query.
    def self.latest_finished(workflow_ids, per: 3)
      ranked = where(workflow_id: workflow_ids).where.not(status: ACTIVE)
                 .select("workflow_runs.*, ROW_NUMBER() OVER (PARTITION BY workflow_id ORDER BY id DESC) AS newest_rank")
      from(ranked, :workflow_runs).where("newest_rank <= ?", per).order(id: :desc).group_by(&:workflow_id)
    end

    def active? = ACTIVE.include?(status)
    def finished? = !active?
    def dry_run? = mode == "dry_run"
    def definition = workflow_version.parsed

    # What the run is about, in a word or two; nil when it is about nothing.
    def subject_label
      if pr_number then "PR ##{pr_number}"
      elsif issue_number then "issue ##{issue_number}"
      end
    end

    # Where what the run is about lives. Harbor doesn't know; a host's
    # subclass says.
    def subject_url = nil

    def cost_usd = runs.sum { |r| r.cost_usd.to_f }.round(4)

    def duration
      return nil unless started_at
      (ended_at || Time.current) - started_at
    end

    # Latest step run per step key (the graph shows one chip per node).
    def latest_step_runs = step_runs.group_by(&:step_key).transform_values(&:last)

    def finish!(status:, error: nil)
      update!(status:, error: error || self.error, ended_at: Time.current, phase: "done")
    end
  end
end
