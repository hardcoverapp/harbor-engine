module Harbor
  module Runner
    # What a runner posts to: a run's output as it is printed, its exit
    # status at the end, and, for an agent session, a request for each file
    # the command needs. There is no login here; each request carries the
    # run's own token (Harbor::RunToken), so these routes must be reachable
    # by runners and by nothing with more power than one run.
    #
    # Every one is a POST, fetching a file included: a firewall in front of
    # the app lets POSTs under /harbor/runner/ through and nothing else.
    # What each does is Harbor::RunnerReport.
    class RunsController < ActionController::API
      MAX_CHUNK = 2.megabytes

      before_action :authenticate

      # POST …/log?offset=N, the body being the next piece of the command's
      # output, as bytes.
      def log
        chunk = request.body.read(MAX_CHUNK + 1).to_s.b
        return head :content_too_large if chunk.bytesize > MAX_CHUNK

        offset = params[:offset].presence && Integer(params[:offset], 10)
        return head :unprocessable_entity if offset&.negative?

        reply Harbor::RunnerReport.log(@run, chunk, offset:, attempt: params[:attempt])
      rescue ArgumentError, TypeError
        head :unprocessable_entity
      end

      # POST …/result, JSON { "exit_status": 0, "signalled": false }.
      def result
        exit_status = Integer(params.require(:exit_status))
        signalled = ActiveModel::Type::Boolean.new.cast(params[:signalled]) || false
        reply Harbor::RunnerReport.result(@run, exit_status:, signalled:, attempt: params[:attempt])
      rescue ArgumentError, TypeError, ActionController::ParameterMissing
        head :unprocessable_entity
      end

      # POST …/bundle/:name, answered with that file of the run's.
      def bundle
        response.headers["Cache-Control"] = "no-store"
        reply Harbor::RunnerReport.bundle(@run, params[:name], attempt: params[:attempt])
      end

      private

      def reply(answer)
        return head answer.status if answer.body.nil?
        render plain: answer.body, status: answer.status, content_type: answer.content_type || "text/plain"
      end

      def authenticate
        token = request.authorization.to_s[/\ABearer (.+)\z/, 1]
        return head :unauthorized unless Harbor::RunToken.valid?(token, params[:id])

        @run = Harbor.run_class.find_by(id: params[:id]) or head :not_found
      end
    end
  end
end
