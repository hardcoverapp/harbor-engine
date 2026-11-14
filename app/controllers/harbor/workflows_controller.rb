module Harbor
  # Workflows: build trigger → step graphs and watch them run. Saving makes a
  # new version; runs pin theirs.
  class WorkflowsController < ApplicationController
    harbor_page :workflows
    helper Harbor::WorkflowsHelper
    helper Harbor::RunsHelper
    before_action :set_workflow, only: %i[show edit update run mode test]

    def index
      @workflows = Harbor.workflow_class.ordered.includes(:current_version).to_a
      since = 7.days.ago
      runs = Harbor.workflow_run_class.where(workflow_id: @workflows.map(&:id)).where("created_at >= ?", since)
      @stats = runs.group(:workflow_id, :status).count.each_with_object(Hash.new { |h, k| h[k] = Hash.new(0) }) do |((wid, status), n), acc|
        acc[wid][status] += n
      end
      # Under each workflow: what is running now, and how its last three runs ended.
      @active_runs = Harbor.workflow_run_class.active.where(workflow_id: @workflows.map(&:id)).recent.group_by(&:workflow_id)
      @finished_runs = Harbor.workflow_run_class.latest_finished(@workflows.map(&:id), per: 3)
    end

    def show
      @definition = @workflow.definition
      @runs = @workflow.workflow_runs.recent.limit(20)
      versions = @workflow.versions
      versions = versions.includes(:created_by_user) if Harbor.config.user_class
      @versions = versions.reverse
      # Deliveries to test the triggers against, for a host that can turn one
      # into trigger data.
      @events = Harbor.config.workflow_event_data ? Harbor.webhook_event_class.order(id: :desc).limit(40) : []
    end

    def new
      @workflow = Harbor.workflow_class.new
      @json = JSON.pretty_generate(self.class.starter)
    end

    def create
      @workflow = Harbor.workflow_class.new(workflow_params.merge(mode: "off"))
      @json = params.dig(:workflow, :definition).to_s
      unless @workflow.valid?
        @errors = @workflow.errors.full_messages
        return render :new, status: :unprocessable_entity
      end
      _, @errors = @workflow.save_definition!(@json, user: harbor_current_user)
      return render(:new, status: :unprocessable_entity) if @errors.any?
      redirect_to workflow_path(@workflow), notice: "Created #{@workflow.name} (version 1). It's off until you switch it to dry run or live."
    end

    def edit
      @json = JSON.pretty_generate(@workflow.current_version&.definition || self.class.starter)
    end

    def update
      @json = params.dig(:workflow, :definition).to_s
      @workflow.assign_attributes(workflow_params.except(:key))
      unless @workflow.valid?
        @errors = @workflow.errors.full_messages
        return render :edit, status: :unprocessable_entity
      end
      before = @workflow.current_version
      version, @errors = @workflow.save_definition!(@json, user: harbor_current_user)
      return render(:edit, status: :unprocessable_entity) if @errors.any?
      @workflow.save!
      notice = version == before ? "Saved #{@workflow.name}; the steps didn't change." : "Saved #{@workflow.name} as version #{version.number}."
      redirect_to workflow_path(@workflow), notice:
    end

    def mode
      mode = params[:mode].to_s
      return redirect_to(workflow_path(@workflow), alert: "Unknown mode") unless Harbor::Workflow::MODES.include?(mode)
      unless @workflow.update(mode:)
        return redirect_to(workflow_path(@workflow), alert: @workflow.errors.full_messages.to_sentence)
      end
      note = if mode == "live" && !Harbor::Workflows.enabled?
        " Workflows are switched off in Settings, so it still only dry-runs."
      end
      redirect_to workflow_path(@workflow), notice: "#{@workflow.name} is now #{mode.tr('_', ' ')}.#{note}"
    end

    # Start by hand. Dry run unless the workflow is live (and the master
    # switch is on) and the person didn't ask for a dry run. What the steps
    # read as the trigger is the host's to say (`config.workflow_manual_start`).
    def run
      input = params[:input].present? ? JSON.parse(params[:input]) : {}
      raise JSON::ParserError, "the input must be an object" unless input.is_a?(Hash)
      trigger, input = manual_start(input)
      run = Harbor::Workflows.start!(@workflow, trigger:, kind: "manual", input:, user: harbor_current_user,
                                                force_dry_run: params[:dry_run] == "1")
      if run
        redirect_to workflow_run_path(run), notice: "Started #{@workflow.name} (#{run.mode.tr('_', ' ')})."
      else
        redirect_to workflow_path(@workflow), alert: "Didn't start: it's already running for that PR/issue, or it has no saved version."
      end
    rescue JSON::ParserError => e
      redirect_to workflow_path(@workflow), alert: "Input isn't valid JSON: #{e.message}"
    end

    # Test with event: which triggers match a stored delivery, and the trigger
    # data the steps would see. "Dry run it" starts a dry run on that event.
    def test
      hook = Harbor.config.workflow_event_data or raise ActionController::RoutingError, "Not Found"
      ev = Harbor.webhook_event_class.find(params[:webhook_event_id])
      trigger = hook.call(ev).to_h
      matched = @workflow.definition.triggers.each_with_index.select { |t, _| Harbor::Workflows.trigger_matches?(t, ev, trigger) }.map(&:last)
      if params[:start] == "1"
        run = Harbor::Workflows.start!(@workflow, trigger:, kind: ev.provider, webhook_event: ev, user: harbor_current_user, force_dry_run: true)
        return redirect_to(workflow_run_path(run), notice: "Dry run started on #{ev.event}.#{ev.action}.") if run
        return redirect_to(workflow_path(@workflow), alert: "Didn't start: one is already running for that PR/issue.")
      end
      @test_result = { "event" => ev, "matched" => matched.map { |i| i + 1 }, "trigger" => trigger }
      show
      render :show
    end

    # Every trigger, input, gate and module the builder offers (from what is
    # registered, so it always matches the builder).
    def reference; end

    # What a new workflow starts as: the host's (`config.workflow_starter`),
    # else one that can be saved and run as it is.
    STARTER = {
      "settings" => {},
      "triggers" => [ { "kind" => "manual" } ],
      "steps" => [
        { "key" => "first_step", "type" => "action", "name" => "Say hello", "action" => "note",
          "message" => "Started by {{trigger.sender}}" }
      ],
      "finally" => []
    }.freeze

    def self.starter = Harbor::Workflows.value(Harbor.config.workflow_starter) || STARTER

    private
      def set_workflow = @workflow = Harbor.workflow_class.find_by!(key: params[:key])

      def manual_start(input)
        hook = Harbor.config.workflow_manual_start
        return hook.call(params, harbor_current_user, input) if hook
        [ { "kind" => "manual", "sender" => harbor_user_label }.compact, input ]
      end

      def workflow_params
        permitted = params.require(:workflow).permit(:key, :name, :description, *Harbor.config.workflow_params, claims: [])
        permitted[:claims] = Array(permitted[:claims]).compact_blank if permitted.key?(:claims)
        permitted
      end
  end
end
