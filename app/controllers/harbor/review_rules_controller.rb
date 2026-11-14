module Harbor
  # The rules: add one, edit its definition (every save is a version), switch
  # its mode (live / shadow / off), roll back, and, where the host has a
  # preview, see what a risk or sign-off would have matched before relying
  # on it.
  class ReviewRulesController < ApplicationController
    harbor_page :reviews
    helper Harbor::ReviewsHelper
    before_action :load_rule, only: %i[show edit update rollback preview]

    # The kinds whose matching can be tried without running anything.
    PREVIEWED = %w[risk signoff].freeze

    def self.previewable?(rule) = Harbor.config.review_rule_preview.present? && rule.kind.in?(PREVIEWED)

    def index = redirect_to(reviews_path)

    def show
      @versions = @rule.versions.reorder(number: :desc).limit(20)
      if @rule.kind == "check"
        @recent = Harbor::ReviewCheckRun.where(review_rule_id: @rule.id).includes(:review_round).order(id: :desc).limit(30)
        done = @recent.select(&:done?)
        @pass_rate = done.empty? ? nil : (100.0 * done.count { |c| %w[passed reused].include?(c.status) } / done.size).round
        @shadow_blocking = @recent.select { |c| c.mode == "shadow" && c.status == "failed" && c.gate == "blocking" }.size
      end
      @preview = Harbor.run_class.find_by(id: params[:preview_run]) if params[:preview_run]
    end

    def new
      rules = Harbor.review_rule_class
      @rule = rules.new(kind: params[:kind].presence_in(ReviewRule::KINDS) || "check", mode: "shadow", **rules.page_defaults)
      @definition_json = JSON.pretty_generate(rules.definition_template(@rule.kind))
    end

    def create
      @rule = Harbor.review_rule_class.new(rule_params.merge(mode: params.dig(:review_rule, :mode).presence || "shadow"))
      save_definition(:new)
    end

    def edit
      @definition_json = JSON.pretty_generate(@rule.definition)
    end

    def update
      @rule.assign_attributes(rule_params.slice(:name, :mode))
      save_definition(:edit)
    end

    def rollback
      _, errors = @rule.roll_back_to!(params[:number].to_i, user: harbor_current_user)
      redirect_to review_rule_path(@rule), (errors.any? ? { alert: errors.join("; ") } : { notice: "Rolled back to v#{params[:number]} (saved as a new version)." })
    end

    # Try a risk's or a sign-off's matching (saved or as edited) the host's
    # way: a run, shown on the rule's page when it finishes.
    def preview
      return redirect_to(review_rule_path(@rule), alert: "This site has no preview for a #{@rule.kind}.") unless self.class.previewable?(@rule)

      definition = params[:definition].present? ? JSON.parse(params[:definition]) : @rule.definition
      run = Harbor.config.review_rule_preview.call(@rule, definition, user: harbor_current_user)
      redirect_to review_rule_path(@rule, preview_run: run.id)
    rescue JSON::ParserError => e
      redirect_to edit_review_rule_path(@rule), alert: "That isn't valid JSON: #{e.message}"
    end

    private

    def load_rule = @rule = Harbor.review_rule_class.find(params[:id])

    def rule_params = params.require(:review_rule).permit(:kind, :key, :repo, :name, :mode)

    def save_definition(template)
      @definition_json = params[:definition].to_s
      definition = JSON.parse(@definition_json)
      _, errors = @rule.save_definition!(definition, user: harbor_current_user)
      @rule.save! if errors.empty? && @rule.changed?
      if errors.empty?
        redirect_to review_rule_path(@rule), notice: "Saved v#{@rule.version_number}#{' in shadow mode' if @rule.shadow?}."
      else
        flash.now[:alert] = errors.join("; ")
        render template, status: :unprocessable_entity
      end
    rescue JSON::ParserError => e
      flash.now[:alert] = "That isn't valid JSON: #{e.message}"
      render template, status: :unprocessable_entity
    rescue ActiveRecord::RecordInvalid => e
      flash.now[:alert] = e.record.errors.full_messages.join("; ")
      render template, status: :unprocessable_entity
    end
  end
end
