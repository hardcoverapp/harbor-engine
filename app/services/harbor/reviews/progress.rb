module Harbor
  module Reviews
    # Percent complete for a round: triage 5%, evidence 70%, code review 25%.
    # Inside evidence each live check counts equally; a running check counts its
    # reported done/total, or its elapsed time against the median of its last
    # 20 runs (capped at 90%). Reused, skipped and finished checks count as done.
    # Shadow checks don't count: they can't hold up a round.
    module Progress
      module_function

      def for(round, checks = round.check_runs.to_a)
        live = checks.select { |c| c.mode == "live" && c.stage == "evidence" }
        done = live.count(&:done?)
        evidence = live.empty? ? 1.0 : live.sum { |c| fraction(c) } / live.size
        review = case round.phase
        when "published", "signoffs" then 1.0
        when "review" then 0.5
        else 0.0
        end
        percent = round.phase == "published" ? 100 : (5 + 70 * evidence + 25 * review).floor
        { "percent" => percent.clamp(0, 100), "done" => done, "total" => live.size,
          "eta_seconds" => eta(live) }.compact
      end

      def fraction(c)
        return 1.0 if c.done?
        return 0.0 unless c.status == "running"
        return (c.progress_done.to_f / c.progress_total).clamp(0.0, 0.95) if c.progress_total.to_i.positive?
        med = median_seconds(c.check_key) or return 0.1
        ((Time.current - (c.started_at || Time.current)) / med).clamp(0.0, 0.9)
      end

      def eta(live)
        running = live.select { |c| c.status == "running" }
        return nil if running.empty?
        running.filter_map do |c|
          med = median_seconds(c.check_key) or next
          [ med - (Time.current - (c.started_at || Time.current)), 0 ].max
        end.max&.round
      end

      def median_seconds(check_key)
        Harbor::ReviewCheckRun.where(check_key:, status: %w[passed failed])
                      .where.not(started_at: nil).where.not(finished_at: nil)
                      .order(id: :desc).limit(20)
                      .pluck(Arel.sql("EXTRACT(EPOCH FROM finished_at - started_at)"))
                      .map(&:to_f).sort.then { |a| a.empty? ? nil : a[a.size / 2] }
      end
    end
  end
end
