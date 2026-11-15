module Harbor
  module Velocity
    # The Scorers tab: per scorer, how the judged runs did over the range,
    # and what the judging cost.
    class Scoring
      attr_reader :since, :now

      def initialize(since:, now: Time.current)
        @since = since
        @now   = now
      end

      def range = since..now

      def scorers = Harbor.scorer_class.ordered.includes(:model_alias)

      def summary(scorer)
        rows = scorer.scored_results.where(scored_at: range)
        total  = rows.count
        passed = rows.where(passed: true).count
        { total:, passed:, failed: total - passed,
          pass_rate: (total.zero? ? nil : (100.0 * passed / total).round),
          series: scorer.weekly_pass_series(since:, now:),
          errors: scorer.scorer_results.where(status: "error", updated_at: range).count,
          by_label: rows.group(:classification).count.sort_by { |_, n| -n } }
      end

      def judge_runs = Harbor.run_class.where(skill: Harbor::Scorer::JUDGE_SKILL, created_at: range)
      def judge_spend = judge_runs.sum(:cost_usd_actual).to_f
      def judge_count = judge_runs.count
    end
  end
end
