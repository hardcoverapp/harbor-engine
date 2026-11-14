module Harbor
  # Scorers: judges that classify finished agent runs against a question you
  # write. Create one, score a few runs by hand to check the judge agrees with
  # you, then raise its sample rate.
  class ScorersController < ApplicationController
    harbor_page :scorers
    helper Harbor::QualityHelper
    before_action :set_scorer, only: %i[show edit update toggle]

    def index
      @scorers = Harbor.scorer_class.ordered.includes(:model_alias)
      @since   = 30.days.ago
      @stats   = @scorers.index_with do |s|
        rows = s.scored_results.where("scored_at >= ?", @since)
        { scored: rows.count, pass_rate: s.pass_rate(since: @since), last: s.scorer_results.recent.first }
      end
    end

    def show
      @since   = 12.weeks.ago.beginning_of_week
      @series  = @scorer.weekly_pass_series(since: @since)
      @results = @scorer.scorer_results.recent.includes(:run, :judge_run).limit(50)
      @totals  = { scored: @scorer.scored_results.count, passed: @scorer.scored_results.where(passed: true).count,
                   errors: @scorer.scorer_results.where(status: "error").count }
    end

    def new
      @scorer = Harbor.scorer_class.draft
    end

    def edit; end

    def create
      @scorer = Harbor.scorer_class.new
      save(:new)
    end

    def update
      save(:edit)
    end

    def toggle
      @scorer.update!(enabled: !@scorer.enabled?)
      redirect_to scorers_path, notice: "#{@scorer.name} #{@scorer.enabled? ? 'enabled' : 'disabled'}."
    end

    private

    def set_scorer = @scorer = Harbor.scorer_class.find(params[:id])

    def save(template)
      attrs = params.require(:scorer).permit(:name, :description, :judge_instructions, :model_alias_id, :pass_threshold,
                                             :sample_rate, :enabled, :self_improvement, :improvement_min_failures,
                                             :improvement_max_age_days, agent_keys: [], task_types: []).to_h
      attrs["agent_keys"] = Array(attrs["agent_keys"]).reject(&:blank?)
      attrs["task_types"] = Array(attrs["task_types"]).reject(&:blank?)
      attrs["classifications"] = Harbor.scorer_class.parse_classifications(params.dig(:scorer, :classifications_text))
      @scorer.assign_attributes(attrs)
      if @scorer.save
        redirect_to scorer_path(@scorer), notice: "#{@scorer.name} saved. It applies to runs that finish from now on."
      else
        render template, status: :unprocessable_entity
      end
    rescue ArgumentError => e
      @scorer.assign_attributes(attrs.except("classifications")) if attrs
      @scorer.errors.add(:classifications, e.message)
      render template, status: :unprocessable_entity
    end
  end
end
