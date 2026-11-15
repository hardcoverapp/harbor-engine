module Harbor
  module AgentSession
    # Follows a session on a runtime where nothing reports by itself: one
    # with no terminal and no runner script, whose backend is asked instead
    # (`poll_session(run)`, which says how long until the next look). The job
    # comes back for as long as the run is running.
    #
    # `chain` is which line of these jobs this one belongs to. Following is
    # begun again when the app comes back up and when a session has gone
    # quiet (`follow`); the run then counts a new chain, and a job left over
    # from an earlier one stops instead of asking beside it.
    class PollJob < ActiveJob::Base
      queue_as :default

      # How soon a look that failed for a reason of its own is made again.
      RETRY = 30.seconds

      # Begins following `run`, in place of any following already under way.
      def self.follow(run, wait: nil)
        chain = run.with_lock do
          state = run.runner_state.to_h
          state = state.merge("poll_chain" => state["poll_chain"].to_i + 1)
          run.update_columns(runner_state: state)
          state["poll_chain"]
        end
        (wait ? set(wait:) : self).perform_later(run.id, chain)
      end

      def perform(run_id, chain)
        run = Harbor.run_class.find_by(id: run_id) or return
        return unless run.running? && AgentSession.session?(run) && run.runner_state.to_h["poll_chain"].to_i == chain.to_i

        again = begin
          backend = AgentSession.backend_for(run) or raise Error, "the runtime it was placed on is gone"
          backend.poll_session(run)
        rescue StandardError => e
          # A look that could not be made says nothing about the session.
          Rails.logger.error("[harbor] run #{run_id}: following the session failed: #{e.class}: #{e.message}")
          RETRY.to_i
        end
        self.class.set(wait: [ again.to_f, 1 ].max.seconds).perform_later(run_id, chain) if again
      end
    end
  end
end
