module Harbor
  module AgentSession
    # Runs one of a session's checks (Watch) when it is due, and comes back
    # for the next look while the session is still running.
    class WatchJob < ActiveJob::Base
      queue_as :default

      def perform(run_id, check)
        run = Harbor.run_class.find_by(id: run_id) or return
        again = Watch.call(run, check)
        self.class.set(wait: [ again.to_f, 1 ].max.seconds).perform_later(run_id, check) if again
      end
    end
  end
end
