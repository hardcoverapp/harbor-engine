module Harbor
  # What reviews cost and whether the rules earn it: rounds per pull request,
  # time to approval, what reuse saved, evidence cost by risk, and each
  # check's cost next to its precision and the bugs that got through.
  class ReviewDashboardsController < ApplicationController
    harbor_page :reviews
    helper Harbor::ReviewsHelper

    def show
      @since = (params[:days].presence || 30).to_i.days.ago
      rounds = Harbor::ReviewRound.where(created_at: @since.., dry_run: false)
      @rounds = rounds.count
      @prs = rounds.distinct.count(:pr_number)
      @rounds_per_pr = @prs.zero? ? 0 : (@rounds.to_f / @prs).round(1)
      cost = ->(scope) { Harbor.run_class.where(id: scope).sum("COALESCE(cost_usd_actual, cost_usd_estimate, 0)").to_f }
      check_runs = Harbor::ReviewCheckRun.joins(:review_round).merge(rounds)
      @evidence_cost = cost.(check_runs.where.not(run_id: nil).select(:run_id))
      # What the reviews themselves cost is the host's to say.
      @review_cost = Harbor.config.review_cost&.call(@since)&.to_f
      @reused = check_runs.where(status: "reused").count
      @by_check = check_runs.group(:check_key).count.map do |key, n|
        runs = check_runs.where(check_key: key).where.not(run_id: nil)
        done = check_runs.where(check_key: key, status: Harbor::ReviewCheckRun::DONE).group(:status).count
        { key:, runs: n, cost: cost.(runs.select(:run_id)), passed: done.slice("passed", "reused").values.sum,
          failed: done["failed"].to_i, errored: done["errored"].to_i }
      end.sort_by { |h| -h[:cost] }
      findings = Harbor::ReviewFeedback.precision_by("finding")
      @precision = Harbor::ReviewFeedback.precision_by("check").merge(findings)
      # The kinds of finding the host declared; with none declared, every
      # kind that has feedback.
      categories = Harbor::Reviews.finding_categories
      @finding_categories = categories.any? ? @precision.select { |k, _| categories.include?(k) } : findings
      @escapes = Harbor::ReviewEscape.where(created_at: @since..).order(id: :desc).limit(20)
      approvals = rounds.where("review->>'verdict' = 'APPROVE'").pluck(:created_at, :finished_at).filter_map { |a, b| b && (b - a) / 60.0 }
      @median_minutes = approvals.empty? ? nil : approvals.sort[approvals.size / 2].round
      risk_costs = Hash.new(0.0)
      rounds.includes(:check_runs).find_each do |r|
        c = cost.(r.check_runs.filter_map(&:run_id))
        Array(r.risks).each { |risk| risk_costs[risk["key"]] += c }
      end
      @by_risk = risk_costs.sort_by { |_, v| -v }
    end
  end
end
