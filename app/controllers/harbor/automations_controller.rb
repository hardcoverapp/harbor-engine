module Harbor
  # The automations: the list of everything the site does on its own, and the
  # form that makes and edits one. Run one now, switch it off, change its
  # schedule; make an agent automation with no deploy.
  class AutomationsController < ApplicationController
    harbor_page :automations
    helper Harbor::AutomationsHelper
    before_action :set_automation, only: %i[edit update destroy run toggle]

    # A job automation is made in code, so the page edits only what a person
    # can sensibly change; an agent automation takes everything.
    JOB_FIELDS = %i[name description category trigger_kind cron enabled allow_concurrent].freeze
    AGENT_FIELDS = (JOB_FIELDS + %i[key agent_key prompt slash_command cwd_key run_as timeout_ms]).freeze

    def index
      @automations = Harbor.automation_class.includes(:agent).ordered.to_a
      @last_runs = Harbor.run_class.where(automation_id: @automations.map(&:id)).recent
                         .group_by(&:automation_id).transform_values(&:first)
      @groups = @automations.group_by(&:category)
    end

    def new
      @automation = Harbor.automation_class.new(kind: "agent", trigger_kind: "manual", **Harbor.automation_class.page_defaults)
    end

    def edit; end

    def create
      @automation = Harbor.automation_class.new(kind: "agent")
      save(:new)
    end

    def update
      save(:edit)
    end

    # Only an automation made on the page is deleted from it: a job
    # automation belongs to the code that made it. Its runs are kept.
    def destroy
      return redirect_to(automations_path, alert: "#{@automation.name} is made by this site's code and can't be deleted here.") if @automation.job?

      @automation.destroy!
      redirect_to automations_path, notice: "#{@automation.name} deleted. Its runs are kept."
    end

    # Fire it now. Lands on the run when there is one already; a job that
    # makes its own run goes to the Runs list, where it appears in a moment.
    def run
      result = Harbor::Automations::Dispatch.call(@automation, trigger_source: "manual", triggered_by_user: harbor_current_user)
      if result.run
        notice = result.note ? "#{@automation.name} is #{result.note}." : "Started #{@automation.name}."
        redirect_to run_path(result.run), notice:
      elsif result.enqueued
        redirect_to runs_path, notice: "#{@automation.name} #{result.note}."
      else
        redirect_to automations_path, alert: "#{@automation.name} didn't start: #{result.note}."
      end
    end

    def toggle
      @automation.update!(enabled: !@automation.enabled?)
      redirect_to automations_path, notice: "#{@automation.name} #{@automation.enabled? ? 'enabled' : 'disabled'}."
    end

    private

    def set_automation = @automation = Harbor.automation_class.find(params[:id])

    def save(template)
      fields = @automation.job? ? JOB_FIELDS : AGENT_FIELDS + Array(Harbor.config.automation_params)
      attrs = params.require(:automation).permit(*fields).to_h
      # An automation's key names its runs' logs: set once.
      attrs.delete("key") if @automation.persisted?
      attrs["key"] = attrs["key"].to_s.parameterize if attrs.key?("key")
      @automation.assign_attributes(attrs)
      Harbor.config.automation_edited&.call(@automation, harbor_current_user, params[:automation])
      if @automation.save
        redirect_to automations_path, notice: "#{@automation.name} saved. Changes apply to its next run."
      else
        render template, status: :unprocessable_entity
      end
    end
  end
end
