module Harbor
  # Every tracked piece of work: the list, and a run's own page with its live
  # log, events and result.
  class RunsController < ApplicationController
    harbor_page :runs
    helper Harbor::RunsHelper

    def index
      @runs = Harbor.run_class.for_page(request.query_parameters.symbolize_keys).limit(100)
    end

    def show
      @run = Harbor.run_class.find(params[:id])
      @live_log = @run.live_log_path
      @live_body = Harbor::LiveLog.read(@live_log)
    end

    # The run's raw stream, exactly as its command printed it: the full record
    # behind the parsed events.
    def raw
      run = Harbor.run_class.find(params[:id])
      file = run.raw_log_file
      return redirect_to run_path(run), alert: "No raw log on disk for this run." unless file && File.file?(file)

      send_file file, type: "application/x-ndjson", filename: "run-#{run.id}.ndjson", disposition: "attachment"
    end

    # Stop a run in progress, or cancel one still waiting (Harbor::RunStop).
    def stop
      run = Harbor.run_class.find(params[:id])
      unless Harbor::RunStop.possible?(run)
        return redirect_back fallback_location: run_path(run),
                             alert: "This run can't be stopped (only a running agent/skill run can)."
      end

      begin
        notice = Harbor::RunStop.call(run, harbor_current_user)
      rescue StandardError => e
        # The host's hook said why, or failed: say so instead of an error page.
        Rails.logger.error("[harbor] stopping run #{run.id} failed: #{e.class}: #{e.message}")
        return redirect_back fallback_location: run_path(run), alert: "Run ##{run.id} wasn't stopped: #{e.message}"
      end
      redirect_back fallback_location: run_path(run), notice: notice
    end

    # Judge this run now with one scorer (scorer_id) or every enabled scorer
    # that applies to it. Re-scoring replaces the earlier verdict.
    def score
      run = Harbor.run_class.find(params[:id])
      unless run.scorable?
        return redirect_back fallback_location: run_path(run),
                             alert: "Only a finished, top-level agent run with a transcript can be scored."
      end
      scorers = params[:scorer_id].present? ? [ Harbor.scorer_class.find(params[:scorer_id]) ] : Harbor.scorer_class.applicable_to(run)
      return redirect_back fallback_location: run_path(run), alert: "No enabled scorer applies to this run." if scorers.empty?

      # One judge per (scorer, run) at a time: the claim is made here, before
      # anything is enqueued, so a double click or a replayed POST can't start
      # a second paid judgement.
      claimed = scorers.select { |scorer| Harbor::ScorerResult.claim!(scorer:, run:) }
      if claimed.empty?
        return redirect_back fallback_location: run_path(run),
                             notice: "Run ##{run.id} is already being judged by #{scorers.map(&:name).to_sentence} — the verdict appears here shortly."
      end
      claimed.each do |scorer|
        Harbor::Scorers::EvaluateJob.perform_later(scorer_id: scorer.id, run_id: run.id, trigger_source: "manual",
                                                   triggered_by_user_id: harbor_current_user.try(:id))
      end
      redirect_back fallback_location: run_path(run),
                    notice: "Judging run ##{run.id} with #{claimed.map(&:name).to_sentence} — the verdict appears here shortly."
    end
  end
end
