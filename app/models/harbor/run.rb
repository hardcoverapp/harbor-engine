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

    enum :status, STATUSES.index_with(&:itself)
    enum :trigger_source, TRIGGER_SOURCES.index_with(&:itself), prefix: :trigger

    scope :top_level, -> { where(parent_run_id: nil) }
    scope :recent, -> { order(Arel.sql("COALESCE(runs.started_at, runs.created_at) DESC")) }
    scope :pending, -> { where(status: %w[queued waiting_for_model]) }
    scope :queued_or_running, -> { where(status: ACTIVE) }
    scope :unresolved, -> { where(resolved_at: nil) }

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
  end
end
