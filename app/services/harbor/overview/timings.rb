module Harbor
  module Overview
    # How long each kind of agent work usually takes and what it costs: median
    # and 90th percentile over recent finished top-level runs, per task type,
    # in one grouped query (Postgres percentile_cont ignores NULL costs).
    #
    # Durations come from runs that ended ok, so a crash at minute one doesn't
    # pull the median down; failed counts how many didn't.
    module Timings
      Row = Struct.new(:task_type, :runs, :failed, :median_seconds, :p90_seconds, :median_cost, :p90_cost,
                       keyword_init: true)

      SECONDS = "EXTRACT(EPOCH FROM (runs.ended_at - runs.started_at))".freeze
      COST    = "COALESCE(runs.cost_usd_actual, runs.cost_usd_estimate)".freeze

      module_function

      def by_task_type(since: Harbor::Overview::WINDOW.ago)
        ok = "runs.status = 'ok'"
        Harbor.run_class.top_level
              .where.not(task_type: nil)
              .where(started_at: since..)
              .where(status: %w[ok error timeout])
              .where.not(ended_at: nil)
              .group(:task_type)
              .pluck(
                :task_type,
                Arel.sql("COUNT(*) FILTER (WHERE #{ok})"),
                Arel.sql("COUNT(*) FILTER (WHERE NOT #{ok})"),
                Arel.sql("PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY #{SECONDS}) FILTER (WHERE #{ok})"),
                Arel.sql("PERCENTILE_CONT(0.9) WITHIN GROUP (ORDER BY #{SECONDS}) FILTER (WHERE #{ok})"),
                Arel.sql("PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY #{COST})"),
                Arel.sql("PERCENTILE_CONT(0.9) WITHIN GROUP (ORDER BY #{COST})")
              )
              .to_h do |task_type, runs, failed, p50, p90, c50, c90|
                [ task_type, Row.new(task_type:, runs:, failed:, median_seconds: p50&.to_f, p90_seconds: p90&.to_f,
                                     median_cost: c50&.to_f, p90_cost: c90&.to_f) ]
              end
      end

      # "4m", "1h 12m", "40s".
      def duration_label(seconds)
        return "—" if seconds.nil?
        s = seconds.round
        return "#{s}s" if s < 60
        m = (s / 60.0).round
        m < 60 ? "#{m}m" : "#{m / 60}h #{m % 60}m"
      end

      def cost_label(usd) = usd.nil? ? "—" : format("$%.2f", usd)
    end
  end
end
