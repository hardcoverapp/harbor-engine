module Harbor
  # Overview, the section's front page: what is set up here and how it has
  # been doing, read from the records each time (Harbor::Overview), with the
  # stage notes edited in place (StageNotesController) and the changes feed
  # with its "this week" filter.
  class OverviewController < ApplicationController
    harbor_page :overview
    helper Harbor::OverviewHelper
    helper Harbor::WorkflowsHelper

    def show
      @snapshot = Harbor::Overview::Snapshot.new
      @stages   = @snapshot.stages
      @notes    = (Harbor.config.user_class ? Harbor::StageNote.includes(:updated_by_user) : Harbor::StageNote).for_stages
      @week     = params[:changes] == "week"
      @changes  = @week ? Harbor::Overview::Changes.this_week : Harbor::Overview::Changes.recent
    end
  end
end
