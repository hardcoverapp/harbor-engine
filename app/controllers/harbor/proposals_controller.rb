module Harbor
  # Proposals: what the drafting runs want to change, with the evidence. A
  # proposal to an agent's prompt or document is applied here with a click; a
  # host's own kind is acted on by the host, through its partials. Nothing is
  # adopted without a person.
  class ProposalsController < ApplicationController
    harbor_page :proposals
    helper Harbor::QualityHelper
    before_action :set_proposal, only: %i[show apply dismiss]

    def index
      @status = Harbor::Proposal::STATUSES.include?(params[:status]) ? params[:status] : "proposed"
      @proposals = Harbor.proposal_class.where(status: @status).recent.includes(:scorer, :run).limit(100)
      @counts = Harbor.proposal_class.group(:status).count
    end

    def show
      @diff = Harbor::Proposals::LineDiff.call(@proposal.before, @proposal.after) if @proposal.agent_target?
      @results = @proposal.scorer_results.includes(:run).to_a
      @results = Harbor::ScorerResult.where(id: Array(@proposal.evidence["scorer_result_ids"])).includes(:run).to_a if @results.empty?
    end

    def apply
      @proposal.apply!(by: harbor_current_user)
      redirect_to proposal_path(@proposal), notice: "Applied to #{@proposal.target_label}. It takes effect on the agent's next run."
    rescue ArgumentError => e
      redirect_to proposal_path(@proposal), alert: e.message
    end

    def dismiss
      @proposal.dismiss!
      redirect_to proposals_path, notice: "Dismissed."
    end

    # Run the check now (Harbor::Proposals::CheckJob), as a run of its own.
    def check
      run = Harbor.run_class.create!(skill: Harbor::Proposals::CheckJob::SKILL, trigger: "self-improvement", trigger_source: "manual",
                                     triggered_by_user_id: harbor_current_user.try(:id))
      Harbor::Proposals::CheckJob.perform_later(run.id)
      redirect_to run_path(run), notice: "Checking for failures worth a proposal."
    end

    private

    def set_proposal = @proposal = Harbor.proposal_class.find(params[:id])
  end
end
