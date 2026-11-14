module Harbor
  # One workflow run: the graph with each step's status, what went into each
  # step and what came out, and the Runs that did the work.
  class WorkflowRunsController < ApplicationController
    harbor_page :workflows
    helper Harbor::WorkflowsHelper
    helper Harbor::RunsHelper
    before_action :set_run, except: :index

    def index
      @runs = Harbor.workflow_run_class.includes(:workflow).recent.limit(100)
      @workflow = Harbor.workflow_class.find_by(key: params[:workflow]) if params[:workflow].present?
      @runs = @runs.where(workflow: @workflow) if params[:workflow].present?
    end

    def show
      @definition = @run.definition
      @latest = @run.latest_step_runs
      @agent_runs = @run.runs.index_by(&:id)
      # What the panel inside the canvas shows: the step list, the run's context,
      # or one step. With nothing asked for it opens on the step in progress, so
      # a live run shows its log straight away; `step=none` closes it.
      @panel = params[:panel].presence_in(%w[steps context])
      unless @panel
        @selected = if params[:step] == "none" then nil
        elsif params[:step].present? then @run.step_runs.find_by(id: params[:step])
        elsif @run.active? then @run.step_runs.select(&:pending?).last
        end
        @panel = "step" if @selected
      end
      @log = step_log(@selected.run) if @selected&.run
    end

    def cancel
      Harbor::Workflows::Control.cancel!(@run, user: harbor_current_user)
      redirect_to workflow_run_path(@run), notice: "Canceling — cleanup steps still run."
    end

    def rerun
      run = Harbor::Workflows::Control.rerun!(@run, user: harbor_current_user)
      return redirect_to(workflow_run_path(run), notice: "Started again.") if run
      redirect_to workflow_run_path(@run), alert: "Didn't start: one is already running for that PR/issue."
    end

    def decide
      approved = params[:decision] == "approve"
      ok = Harbor::Workflows::Control.decide!(@run, step_run_id: params[:step_run_id], approved:, user: harbor_current_user, note: params[:note])
      redirect_to workflow_run_path(@run), (ok ? { notice: approved ? "Approved." : "Rejected." } : { alert: "That step isn't waiting for a decision." })
    end

    private
      # The end of an agent run's live log, for the step panel. Only the tail is
      # read: the panel refreshes every few seconds and a log runs to megabytes.
      def step_log(run)
        path = run.live_log_path or return nil
        { path:, body: nil, clipped: false }.merge(Harbor::LiveLog.tail(path) || {})
      end

      def set_run = @run = Harbor.workflow_run_class.includes(:workflow, :workflow_version, step_runs: :run).find(params[:id])
  end
end
