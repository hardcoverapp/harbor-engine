module Harbor
  module AgentSession
    # Runs one of a session's checks (Watch) when it is due, and comes back
    # for the next look while the session is still running.
    #
    # `round` is which set of checks this one belongs to. A session's checks
    # are queued again when the app comes back up (AgentSession.recover!), in
    # case the queue lost them; the run then counts a new round, and a check
    # left over from an earlier one stops instead of running beside it.
    class WatchJob < ActiveJob::Base
      queue_as :default

      def perform(run_id, check, round = nil)
        run = Harbor.run_class.find_by(id: run_id) or return
        return unless run.runner_state.to_h["watch_round"].to_i == round.to_i

        again = Watch.call(run, check)
        self.class.set(wait: [ again.to_f, 1 ].max.seconds).perform_later(*[ run_id, check, round ].compact) if again
      end
    end
  end
end
