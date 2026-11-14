module Harbor
  # One scorer's verdict on one run: the classification the judge chose, the
  # score that label carries, whether that passes, and the judge's reasoning.
  # Re-scoring a run replaces its row. judge_run is the child run the judge
  # ran as (cost, transcript, model).
  class ScorerResult < ApplicationRecord
    self.table_name = "scorer_results"

    STATUSES = %w[queued ok error].freeze

    # A queued claim older than this belongs to a judge that never reported
    # back (a worker died); it can be claimed again. It has to outlive
    # anything a judge can legitimately take (`config.scorer_judge_wait`), so
    # a judge still running is never "stale" while it can finish.
    def self.stale_claim_after
      wait = Harbor.config.scorer_judge_wait
      wait.respond_to?(:call) ? wait.call : wait
    end

    belongs_to :scorer, class_name: Harbor.class_name_for(:scorer_class), optional: false
    belongs_to :run, class_name: Harbor.class_name_for(:run_class), optional: false
    belongs_to :judge_run, class_name: Harbor.class_name_for(:run_class), optional: true
    # The proposal that reviewed this failure (nil until a drafting run has
    # looked at it).
    belongs_to :proposal, class_name: Harbor.class_name_for(:proposal_class), optional: true, inverse_of: :scorer_results

    validates :status, inclusion: { in: STATUSES }

    scope :scored, -> { where(status: "ok") }
    scope :failed, -> { scored.where(passed: false) }
    scope :passed, -> { scored.where(passed: true) }
    scope :recent, -> { order(Arel.sql("COALESCE(scored_at, created_at) DESC")) }
    # Failures no proposal has looked at and no drafting run is looking at
    # right now (a claim older than this belongs to a run that never
    # answered).
    CLAIM_TTL = 2.hours
    scope :unreviewed, -> { where(reviewed_at: nil).where("claimed_at IS NULL OR claimed_at < ?", CLAIM_TTL.ago) }

    # Claim these failures for one drafting run, atomically: one conditional
    # UPDATE that only takes rows nobody else holds, returning the ids it got.
    # Two checks racing for the same batch can't both win any of it.
    def self.claim_for_review!(ids)
      ids = Array(ids).map(&:to_i).reject(&:zero?)
      return [] if ids.empty?
      sql = sanitize_sql_array([ <<~SQL, ids, CLAIM_TTL.ago ])
        UPDATE scorer_results SET claimed_at = CURRENT_TIMESTAMP
        WHERE id IN (?) AND reviewed_at IS NULL AND (claimed_at IS NULL OR claimed_at < ?)
        RETURNING id
      SQL
      connection.select_values(sql).map(&:to_i)
    end

    def scored? = status == "ok"
    def queued? = status == "queued"

    # Claim the (scorer, run) pair for one judge. Exactly one caller gets the
    # row back while a judgement is pending: a second "Score now", a replayed
    # POST, or the sampler arriving at the same time get nil and enqueue
    # nothing. Once the verdict is in (or the claim went stale) it can be
    # claimed again, which is how re-scoring works.
    def self.claim!(scorer:, run:)
      row = find_or_create_by!(scorer:, run:)
      return row if row.previously_new_record?
      row.with_lock do
        return nil if row.queued? && row.updated_at > stale_claim_after.ago
        # A re-score starts from nothing: the old verdict must not show beside
        # a pending or failed new one.
        row.update!(status: "queued", error: nil, judge_run: nil,
                    classification: nil, score: nil, passed: nil, reasoning: nil, scored_at: nil)
      end
      row
    rescue ActiveRecord::RecordNotUnique
      retry
    end
  end
end
