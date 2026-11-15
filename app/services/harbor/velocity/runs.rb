module Harbor
  module Velocity
    # The Runs tab: how many runs there were over the range, how they ended,
    # and whose they were. Plain aggregates over runs, nothing cached.
    class Runs
      FAILED = %w[error timeout].freeze

      attr_reader :since, :now

      def initialize(since:, now: Time.current)
        @since = since
        @now   = now
      end

      def range = since..now

      def runs = Harbor.run_class.where(created_at: range)

      def count = runs.count

      # { "ok" => 12, "error" => 1, … }
      def by_status = @by_status ||= runs.group(:status).count

      def ok = by_status["ok"].to_i
      def failed = FAILED.sum { |status| by_status[status].to_i }
      def active = Harbor::Run::ACTIVE.sum { |status| by_status[status].to_i }

      # Share of the runs that ended ok or failed that failed; nil with none.
      def failure_rate = (ok + failed).zero? ? nil : (100.0 * failed / (ok + failed)).round

      # How long a run that ended ok took, in seconds; nil with none.
      def median_seconds
        runs.where(status: "ok").where.not(started_at: nil, ended_at: nil)
            .pick(Arel.sql("PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY EXTRACT(EPOCH FROM (runs.ended_at - runs.started_at)))"))&.to_f
      end

      # [[week_start_date, runs]] for the weeks in range.
      def weekly
        counts = runs.group(Arel.sql("DATE_TRUNC('week', created_at)")).count.transform_keys(&:to_date)
        first = since.to_date.beginning_of_week
        last  = now.to_date.beginning_of_week
        (0..).lazy.map { |i| first + (7 * i) }.take_while { |d| d <= last }.map { |w| [ w, counts[w].to_i ] }.to_a
      end

      # { [agent key, status] => runs }
      def by_agent = runs.where.not(agent_key: nil).group(:agent_key, :status).count

      # [[task type, runs]], most first: top-level runs, so the runs a run
      # delegated aren't counted beside it.
      def by_task_type
        runs.top_level.where.not(task_type: nil).group(:task_type).count.sort_by { |type, n| [ -n, type ] }
      end

      # [[runtime name, runs]], most first, for the runs that were placed.
      def by_runtime
        counts = runs.where.not(runtime_id: nil).group(:runtime_id).count
        names = Harbor.runtime_class.where(id: counts.keys).pluck(:id, :name).to_h
        counts.map { |id, n| [ names[id] || "Runtime ##{id}", n ] }.sort_by { |name, n| [ -n, name ] }
      end
    end
  end
end
