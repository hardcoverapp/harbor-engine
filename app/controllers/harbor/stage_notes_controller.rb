module Harbor
  # A stage's note on Overview, edited in place inside the stage's Turbo
  # frame. Saving also hands the note to the host to keep outside the
  # database (Harbor::StageNote, `config.export`).
  class StageNotesController < ApplicationController
    harbor_page :overview
    helper Harbor::OverviewHelper
    before_action :set_stage

    TURBO_STREAM = "text/vnd.turbo-stream.html".freeze

    # The note as the page shows it (Cancel from the editor).
    def show
      render partial: "harbor/overview/note", locals: { stage: @stage, note: Harbor::StageNote.find_by(stage_key: @stage.key) }
    end

    def edit
      @note = Harbor::StageNote.find_or_initialize_by(stage_key: @stage.key)
    end

    def update
      @note = Harbor::StageNote.find_or_initialize_by(stage_key: @stage.key)
      @note.assign_attributes(body: params.dig(:factory_note, :body).to_s.strip, updated_by_user_id: harbor_current_user.try(:id))
      unless @note.save
        return render :edit, status: :unprocessable_entity
      end
      return redirect_to("#{overview_path}##{@stage.anchor}", notice: "Saved the #{@stage.title} note.") unless turbo_stream?

      note = render_to_string(partial: "harbor/overview/note", formats: [ :html ], locals: { stage: @stage, note: @note })
      render body: helpers.content_tag("turbo-stream", helpers.content_tag(:template, note),
                                       action: "replace", target: helpers.harbor_stage_note_frame(@stage)),
             content_type: TURBO_STREAM
    end

    private
      # Whether the form was sent by Turbo, which swaps the frame in place.
      # Read from the header, so it holds in a host without turbo-rails too.
      def turbo_stream? = request.headers["Accept"].to_s.include?(TURBO_STREAM)

      def set_stage
        @stage = Harbor::Overview.find_stage(params[:stage_key]) or raise ActiveRecord::RecordNotFound
      end
  end
end
