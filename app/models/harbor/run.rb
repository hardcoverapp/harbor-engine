module Harbor
  # One tracked piece of background work: an agent session, a scheduled job, a
  # backup. Every background action is a Run with a status, a log and a cost,
  # so nothing happens out of sight.
  #
  # A host can use this class as it is, or extend it with what is its own:
  #
  #   class Run < Harbor::Run
  #     belongs_to :triggered_by_user, class_name: "User", optional: true
  #   end
  #
  # and name that class in `Harbor.configure { |c| c.run_class = "Run" }`, so
  # Harbor builds and finds the host's runs, with the host's behaviour.
  class Run < ApplicationRecord
    self.table_name = "runs"

    STATUSES = %w[queued waiting_for_model running ok error timeout skipped canceled].freeze
    ACTIVE = %w[queued waiting_for_model running].freeze
    FINISHED = (STATUSES - ACTIVE).freeze
    TRIGGER_SOURCES = %w[manual cron webhook watcher agent workflow].freeze

    has_many :run_events, class_name: "Harbor::RunEvent", foreign_key: :run_id, dependent: :delete_all, inverse_of: :run

    # A run an agent delegated (one agent spawning another) is a child Run. The
    # parent's actual cost already includes it (the CLI reports session
    # totals), so a child carries an estimate as the breakdown, not an addend.
    belongs_to :parent_run, class_name: Harbor.class_name_for(:run_class), optional: true, inverse_of: :child_runs
    has_many :child_runs, class_name: Harbor.class_name_for(:run_class), foreign_key: :parent_run_id,
                          inverse_of: :parent_run, dependent: :nullify

    # The automation this run fired for; nil for a run started any other way.
    belongs_to :automation, class_name: Harbor.class_name_for(:automation_class), optional: true, inverse_of: :runs

    # The workflow run this is one step of, when it is one.
    belongs_to :workflow_run, class_name: Harbor.class_name_for(:workflow_run_class), optional: true, inverse_of: :runs

    # A workflow step's Run finished: hand the result back and move the
    # workflow on.
    after_update_commit :complete_workflow_step, if: -> { workflow_run_id && saved_change_to_status? && finished? }

    # Scorers' verdicts on this run. A judge runs as a child run of the run it
    # grades (Harbor::Scorers::EvaluateJob).
    has_many :scorer_results, class_name: "Harbor::ScorerResult", foreign_key: :run_id, dependent: :destroy, inverse_of: :run

    # A finished agent run with a transcript may be sampled by the scorers.
    after_update_commit :sample_for_scoring,
                        if: -> { saved_change_to_status? && scorable? && Harbor.config.scorer_judge && Harbor.scorer_class.enabled.exists? }

    enum :status, STATUSES.index_with(&:itself)
    enum :trigger_source, TRIGGER_SOURCES.index_with(&:itself), prefix: :trigger

    scope :top_level, -> { where(parent_run_id: nil) }
    scope :recent, -> { order(Arel.sql("COALESCE(runs.started_at, runs.created_at) DESC")) }
    scope :pending, -> { where(status: %w[queued waiting_for_model]) }
    scope :queued_or_running, -> { where(status: ACTIVE) }
    scope :unresolved, -> { where(resolved_at: nil) }

    # What the Runs page lists, newest first: top-level runs, each with the
    # runs it delegated nested under it. `filters` is the page's query string
    # as a hash. Harbor has no filters of its own; a host overrides this to
    # add one, or to load what its rows show in the same query.
    def self.for_page(_filters = {}) = top_level.recent.includes(:child_runs)

    # Where this run's live log is, relative to the log location; nil when the
    # run has nothing to name a log by. A run restarted on another model logs
    # each attempt to its own file.
    def live_log_path = Harbor.config.log_path.call(self)

    def log_attempt_suffix
      attempt = Array(input["model_switches"]).size
      attempt.positive? ? "-attempt-#{attempt + 1}" : ""
    end

    # Short label for a list of runs.
    def label
      return loader.to_s.tr("-", " ").titleize if loader.present?
      return skill if skill.present?
      return [ agent_key, task_type ].compact.join(" · ") if agent_key.present? || task_type.present?
      "(unlabelled)"
    end

    # Best-known cost: the CLI-reported actual when there is one, the
    # token-based estimate (delegated child runs) otherwise.
    def cost_usd = cost_usd_actual || cost_usd_estimate

    # Child runs this run's session spawned and billed into its total, for the
    # cost breakdown on the run's page. A scorer's judge is a child too (for
    # the link) but a session with a bill of its own, so it is left out. A
    # host whose runs have other children with their own bill overrides this
    # to leave those out as well.
    def delegated_runs = child_runs.reject { |child| child.skill == Harbor::Scorer::JUDGE_SKILL }

    # The judges that graded this run.
    def judge_runs = child_runs.select { |child| child.skill == Harbor::Scorer::JUDGE_SKILL }

    # Something a scorer can judge: a top-level agent run that ran to a result
    # and left a transcript. Judge runs themselves are never scored.
    def scorable?
      %w[ok error timeout].include?(status) && parent_run_id.nil? && agent_key.present? &&
        skill != Harbor::Scorer::JUDGE_SKILL && raw_log_path.present?
    end

    # A verdict is on its way: the run's page keeps refreshing.
    def awaiting_verdict? = scorer_results.any? { |r| r.queued? && r.updated_at > Harbor::ScorerResult.stale_claim_after.ago }

    # What this run cost without its delegated runs: its total is the whole
    # session's, so its own share is the total less the children's estimates.
    def own_cost_usd
      return cost_usd if delegated_runs.empty?
      [ cost_usd.to_f - delegated_runs.sum { |child| child.cost_usd.to_f }, 0 ].max.round(6)
    end

    # The file holding the run's raw stream (exactly what its command
    # printed), or nil for a run that kept none. Harbor keeps it beside the
    # live log; a host that keeps some runs' streams elsewhere overrides this.
    def raw_log_file = raw_log_path.presence && Harbor::LiveLog.absolute(raw_log_path)

    # "421k in (388k cached) / 19k out". Cache reads stay distinct from fresh
    # input: they cost a fraction, and merging them would misrepresent cheap runs.
    def token_summary
      return nil unless input_tokens || output_tokens
      inp = self.class.abbrev_tokens(input_tokens.to_i + cache_read_tokens.to_i + cache_creation_tokens.to_i)
      out = self.class.abbrev_tokens(output_tokens.to_i)
      cached = cache_read_tokens.to_i.positive? ? " (#{self.class.abbrev_tokens(cache_read_tokens)} cached)" : ""
      "#{inp} in#{cached} / #{out} out"
    end

    def self.abbrev_tokens(n)
      n = n.to_i
      n >= 1_000 ? "#{(n / 1000.0).round}k" : n.to_s
    end

    # Claim a Run for an idempotent trigger (a webhook delivery id plus what it
    # asks for). Returns nil when the key was already claimed: the caller logs
    # and drops the duplicate instead of doing the work twice.
    def self.claim!(idempotency_key:, **attrs)
      return create!(**attrs) if idempotency_key.blank?
      create!(idempotency_key:, **attrs)
    rescue ActiveRecord::RecordNotUnique
      nil
    end

    def duration_seconds
      return nil unless started_at && ended_at
      ended_at - started_at
    end

    def finished? = FINISHED.include?(status)
    def queued_or_running_status? = ACTIVE.include?(status)
    def pending? = queued? || waiting_for_model?
    def failed? = error? || timeout?

    # A person marked this failed run done. It keeps its error status (the
    # failure happened and stays visible); the stamp says nobody needs to act
    # on it, and stops any automatic retry.
    def resolved? = resolved_at.present?
    def resolvable? = failed? && !resolved?

    # Can a Stop button interrupt this? A queued agent run always (its job sees
    # the Run finished and drops the work); a running one only when it drives
    # an agent process. A data fetch on a job thread has nothing to kill.
    def cancelable?
      return task_type.present? if pending?
      running? && (agent_key.present? || skill.present?)
    end

    # Mark running, keeping the first start time.
    def start!
      update!(status: "running", started_at: (started_at || Time.current))
    end

    # Finish with a terminal status and optional output or error.
    def finish!(status:, output: nil, error: nil)
      update!(status:, output: output.presence || self.output, error: error, ended_at: Time.current)
    end

    private
      def complete_workflow_step = Harbor::Workflows::StepCompletion.from_run(self)

      def sample_for_scoring = Harbor::Scorers::SampleJob.perform_later(id)
  end
end
