module Harbor
  module Runner
    # What a runner posts to: a run's output as it is printed, and its exit
    # status at the end. There is no login here; each request carries the
    # run's own token (Harbor::RunToken), so these routes must be reachable by
    # runners and by nothing with more power than one run's log.
    class RunsController < ActionController::API
      MAX_CHUNK = 2.megabytes

      before_action :authenticate

      # POST …/log, the body being the next piece of the command's output.
      def log
        chunk = request.body.read(MAX_CHUNK + 1).to_s
        return head :content_too_large if chunk.bytesize > MAX_CHUNK

        Harbor::LiveLog.append(@run.live_log_path, chunk.force_encoding(Encoding::UTF_8).scrub("?"))
        head :no_content
      end

      # POST …/result, JSON { "exit_status": 0 }.
      def result
        exit_status = Integer(params.require(:exit_status))
        if Harbor.config.run_reported
          Harbor.config.run_reported.call(@run, exit_status: exit_status)
        elsif !@run.finished?
          @run.finish!(status: exit_status.zero? ? "ok" : "error",
                       error: (exit_status.zero? ? nil : "The command exited with status #{exit_status}."))
        end
        head :no_content
      rescue ArgumentError, TypeError, ActionController::ParameterMissing
        head :unprocessable_entity
      end

      private

      def authenticate
        token = request.authorization.to_s[/\ABearer (.+)\z/, 1]
        return head :unauthorized unless Harbor::RunToken.valid?(token, params[:id])

        @run = Harbor.run_class.find_by(id: params[:id]) or head :not_found
      end
    end
  end
end
