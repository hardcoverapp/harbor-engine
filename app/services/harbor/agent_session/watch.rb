module Harbor
  module AgentSession
    # The checks that end a session nobody else will: one that has had its
    # time, one that has printed nothing for too long, and one whose runner
    # has gone without a word. A fourth starts an interrupted session again
    # (Interruption). Each looks at the run as it is now, so it is harmless
    # run late, twice, or after the session is over. Each returns how long
    # until it should look again, or nil when there is nothing more to watch.
    module Watch
      CHECKS = %w[timeout idle silent resume].freeze
      # A session is given this long to get its terminal before one without
      # is taken to have been cut off while starting.
      STARTING = 10.minutes

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
        # Time spent interrupted is not the session's: it is given back when
        # the session starts again, and the limit is looked at then.
        return Interruption::RETRY.to_i if Interruption.interrupted?(run)

        AgentSession.stop!(run, reason: "timeout", note: "Stopped: it had #{duration(state['timeout'])} and was still running.")
        nil
      end

      # Stopped when nothing has been heard for the session's idle limit.
      def idle(run)
        limit = run.runner_state.to_h["idle_timeout"].to_i
        return nil unless limit.positive?

        quiet = Time.current - AgentSession.last_heard(run)
        return limit - quiet if quiet < limit
        return Interruption::RETRY.to_i if Interruption.interrupted?(run)

        AgentSession.stop!(run, reason: "timeout", note: "Stopped: nothing was printed for #{duration(limit)}.")
        nil
      end

      # A runner that dies with its machine, or loses the network for good,
      # never reports. A runner says it is there every half minute even when
      # its command prints nothing, so when nothing at all has come for a
      # while the runtime is asked whether the terminal still has the command
      # in it. If not, no result is coming: the session was cut off, and is
      # started again where it stopped (Interruption), or finished as an
      # error once it has been started again as often as it may. A quiet
      # session whose terminal is still busy is left alone.
      #
      # A session with no terminal at all was cut off while it was being
      # started (the app went down in the middle of it).
      def silent(run)
        limit = silent_after
        return limit if Interruption.interrupted?(run)
        quiet = Time.current - AgentSession.last_alive(run)
        return limit - quiet if quiet < limit

        session = AgentSession.session_of(run)
        if session.nil?
          starting = [ limit, STARTING ].max
          return starting - quiet if quiet < starting
          Finisher.call(run, interrupted: true, error: "The session was cut off while it was being started.")
        elsif AgentSession.backend_for(run).exited?(session)
          Finisher.call(run, interrupted: true,
                             error: "The runner stopped reporting: nothing arrived for #{duration(quiet)} and its terminal is gone.")
        end
        run.reload.running? ? limit : nil
      rescue StandardError => e
        # The runtime could not be asked. That says nothing about the run.
        Rails.logger.error("[harbor] run #{run.id}: silent-runner check failed: #{e.class}: #{e.message}")
        limit
      end

      # Starts an interrupted session again, and comes back for as long as
      # its runtime can't be asked.
      def resume(run) = Interruption.resume(run)

      def silent_after = Harbor::Setting.get(:agent_session_silent_minutes).to_i.minutes

      def duration(seconds) = ActiveSupport::Duration.build(seconds.to_i).inspect
    end
  end
end
