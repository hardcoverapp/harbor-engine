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

    private
      def harbor_current_user = respond_to?(:current_user, true) ? send(:current_user) : nil
  end
end
