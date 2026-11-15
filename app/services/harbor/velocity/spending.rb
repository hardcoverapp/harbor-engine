module Harbor
  module Velocity
    # The Spending tab: what the agents cost over the range, and where it
    # went, per week, per agent and per model. Costs are the actuals each
    # run reported (a parent's total includes the runs it delegated, so only
    # top-level runs are summed).
    class Spending
      attr_reader :since, :now

      def initialize(since:, now: Time.current)
        @since = since
        @now   = now
      end

      def range = since..now

      # Top-level runs (a parent's total already includes the runs it
      # delegated) plus scorer judges, which are separate sessions with their
      # own bill even though they hang off the run they graded.
      def runs
        Harbor.run_class.where(created_at: range).where("runs.parent_run_id IS NULL OR runs.skill = ?", Harbor::Scorer::JUDGE_SKILL)
      end

      def costed = runs.where.not(cost_usd_actual: nil)

      def total = costed.sum(:cost_usd_actual).to_f
      def run_count = runs.count
      def costed_count = costed.count

      def weekly
        counts = costed.group(Arel.sql("DATE_TRUNC('week', created_at)")).sum(:cost_usd_actual)
                       .transform_keys(&:to_date)
        first = since.to_date.beginning_of_week
        last  = now.to_date.beginning_of_week
        (0..).lazy.map { |i| first + (7 * i) }.take_while { |d| d <= last }
             .map { |w| [ w, (counts[w] || 0).to_f.round(2) ] }.to_a
      end

      # [[agent key, cost, runs]], most expensive first.
      def by_agent
        spend = costed.where.not(agent_key: nil).group(:agent_key).sum(:cost_usd_actual)
        counts = runs.where.not(agent_key: nil).group(:agent_key).count
        spend.map { |k, c| [ k, c.to_f, counts[k] || 0 ] }.sort_by { |_, c, _| -c }
      end

      # [[model, cost, runs]], most expensive first.
      def by_model
        costed.group(:model).pluck(:model, Arel.sql("SUM(cost_usd_actual)"), Arel.sql("COUNT(*)"))
              .sort_by { |_, c, _| -c.to_f }
      end
    end
  end
end
