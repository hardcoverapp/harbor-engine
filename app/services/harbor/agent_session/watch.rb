module Harbor
  module AgentSession
    # The checks that end a session nobody else will: one that has had its
    # time, one that has printed nothing for too long, and one whose runner
    # has gone without a word. Each looks at the run as it is now, so it is
    # harmless run late, twice, or after the session is over. Each returns
    # how long until it should look again, or nil when there is nothing more
    # to watch.
    module Watch
      CHECKS = %w[timeout idle silent].freeze

      module_function

      def call(run, check)
        return nil unless CHECKS.include?(check.to_s) && run.running? && AgentSession.session?(run)
        public_send(check, run)
      end

      # The whole session has a time limit, fixed when it started.
      def timeout(run)
        state = run.runner_state.to_h
        at = state["timeout_at"].presence && Time.zone.parse(state["timeout_at"])
        return nil unless at
        return at - Time.current if at > Time.current

        AgentSession.stop!(run, reason: "timeout", note: "Stopped: it had #{duration(state['timeout'])} and was still running.")
        nil
      end

      # Stopped when nothing has been heard for the session's idle limit.
      def idle(run)
        limit = run.runner_state.to_h["idle_timeout"].to_i
        return nil unless limit.positive?

        quiet = Time.current - AgentSession.last_heard(run)
        return limit - quiet if quiet < limit

        AgentSession.stop!(run, reason: "timeout", note: "Stopped: nothing was printed for #{duration(limit)}.")
        nil
      end

      # A runner that dies with its machine, or loses the network for good,
      # never reports. When a session has been quiet for a while its runtime
      # is asked whether the terminal still has the command in it; if not,
      # no result is coming and the run is finished as an error. A quiet
      # session whose terminal is still busy is left alone: an agent can
      # think for a long time.
      def silent(run)
        limit = silent_after
        quiet = Time.current - AgentSession.last_heard(run)
        return limit - quiet if quiet < limit

        session = AgentSession.session_of(run)
        return nil unless session
        return limit unless AgentSession.backend_for(run).exited?(session)

        Finisher.call(run, error: "The runner stopped reporting: nothing arrived for #{duration(quiet)} and its terminal is gone.")
        nil
      rescue StandardError => e
        # The runtime could not be asked. That says nothing about the run.
        Rails.logger.error("[harbor] run #{run.id}: silent-runner check failed: #{e.class}: #{e.message}")
        limit
      end

      def silent_after = Harbor::Setting.get(:agent_session_silent_minutes).to_i.minutes

      def duration(seconds) = ActiveSupport::Duration.build(seconds.to_i).inspect
    end
  end
end
