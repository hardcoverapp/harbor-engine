module Harbor
  module AgentSession
    # A session cut off by something that was not its own ending: the machine
    # it ran on restarted, Orca was shut down, its terminal was closed under
    # it, or the app went down while it was being started. The work is not
    # over, so the run is not finished. It is started again in the worktree
    # it already has, and the agent carries on from where it stopped.
    #
    # The finisher is what notices (Finisher#interrupted?) and marks the run:
    #
    #   runner_state["interrupted"]    "at", "reason", the agent's own
    #                                  "session_id" when it had one, and
    #                                  "starting_at" while a start is under way
    #   runner_state["interruptions"]  how many times this has happened
    #
    # `resume` then starts it again, and is called again (WatchJob, "resume")
    # for as long as the runtime can't be asked: an Orca that is still coming
    # back up refuses, and is asked again a minute later.
    #
    #   claude, which had a session   `claude --resume <its session>` with a
    #                                  short prompt saying what happened: the
    #                                  conversation so far is all still there
    #   anything else                  the same command again, in the same
    #                                  worktree, told that an earlier attempt
    #                                  was cut off and its work may be there
    #
    # The time a session spent interrupted is not counted against its timeout.
    # Its capacity slots are leases sized for the timeout as first given, so
    # after a long interruption they can lapse before the session ends; until
    # it does, its agent or runtime may take one session more than its limit.
    module Interruption
      # How long an interrupted session is kept for a runtime that can't be
      # asked. After that it is finished as an error.
      WINDOW = 6.hours
      RETRY = 1.minute
      # A start that was claimed and never recorded (the process died in the
      # middle of it) is given up on after this long, and tried again.
      CLAIM = 10.minutes

      # The prompt of a session that continues its own conversation.
      CONTINUE = <<~TEXT.squish.freeze
        This run was interrupted: the machine or terminal it was running in was restarted while you were
        working. Nothing else has changed. You are back in the same working directory, with the conversation
        so far. A command that was running when it happened may have been cut off part-way, so check what
        state things are in before relying on it. Then carry on from where you stopped and finish the task.
      TEXT

      # Added to the system prompt of a session started over from its first
      # prompt, when there was no conversation to continue.
      STARTED_OVER = <<~TEXT.squish.freeze
        An earlier attempt at this run was interrupted when the machine or terminal it was running in was
        restarted. The working directory is the one that attempt used and may hold its unfinished work:
        look at what is already there before you start, and continue it rather than doing it again.
      TEXT

      module_function

      # How many times one session may be started again (a setting; 0: never).
      def allowed = Harbor::Setting.get(:agent_session_resume_attempts).to_i

      def interrupted?(run) = run.runner_state.to_h["interrupted"].present?

      # Starts an interrupted session again. Returns how long until it should
      # be tried again, or nil when there is nothing more to do: it was
      # started, or the run is over, or it was never interrupted.
      def resume(run)
        state = claim(run)
        return state if state.nil? || state.is_a?(Numeric)
        return give_up(run, state) if state == :expired

        start(run, state)
        nil
      rescue StandardError => e
        # The runtime could not be asked, or refused. That says nothing about
        # the work: the claim is dropped and it is tried again.
        unclaim(run, e)
        RETRY.to_i
      end

      # Under the run's lock: this call alone goes on to start the session.
      # Each try is a new attempt, so a terminal from an earlier try that
      # did start, unrecorded, is refused when it reports.
      def claim(run)
        run.with_lock do
          state = run.runner_state.to_h.deep_dup
          cut = state["interrupted"]
          next nil unless run.running? && cut.present?
          next RETRY.to_i if cut["starting_at"].present? && Time.zone.parse(cut["starting_at"]) > CLAIM.ago
          next :expired if Time.zone.parse(cut["at"]) < WINDOW.ago

          continuing = cut["session_id"].present? && state["cli"] == "claude" && state["session"].present?
          state["interrupted"] = cut.merge("starting_at" => Time.current.iso8601)
          state["attempt"] = state["attempt"].to_i + 1
          state["continuing"] = continuing ? true : nil
          state["started_over"] = continuing ? nil : true
          # Continuing is a --resume like any other: if the agent's session
          # turns out to be gone, the finisher starts it once more without.
          state.merge!("resume_session_id" => cut["session_id"], "resume_fallback" => nil) if continuing
          run.update_columns(runner_state: state.compact)
          state.compact
        end
      end

      def start(run, state)
        backend = AgentSession.backend_for(run) or raise Error, "the runtime it was placed on is gone"
        cut = state["interrupted"]
        kept = run.input.to_h["agent_session"].to_h
        command = Command.from(kept["command"], mcp_config: kept["mcp"])
        command = command.continuing(cut["session_id"]) if state["continuing"]
        held = AgentSession.session_of(run)

        # Whatever is left of the old terminal, and anything else in a
        # worktree that is this run's alone, goes first: two agents must
        # never work in it at once.
        fresh = if held && backend.clear(held)
          backend.restart(held, run:, command: command.shell, bundle: command.bundle, attempt: state["attempt"])
        else
          # No worktree: the session was cut off while it was being started,
          # or the server has lost the one it had. A leftover by the run's
          # name is removed, and it starts in a new one.
          backend.discard(run)
          backend.start(run:, command: command.shell, base: state["base"], bundle: command.bundle, attempt: state["attempt"])
        end

        over = run.with_lock do
          next true if run.finished?
          now = Time.current
          current = run.runner_state.to_h.deep_dup
          away = now - Time.zone.parse(cut["at"])
          current["timeout_at"] = (Time.zone.parse(current["timeout_at"]) + away).iso8601 if current["timeout_at"].present?
          # Being started again counts as being heard from.
          current.merge!("last_seen_at" => now.iso8601, "alive_at" => now.iso8601)
          # A backend that starts the command later records the session itself.
          current["session"] = fresh.to_h if fresh.to_h.present?
          current.delete("interrupted")
          run.update_columns(command: command.display, runner_state: current)
          false
        end
        # Stopped in the meantime: the new terminal has nothing to do.
        return (backend.stop(fresh) rescue nil) if over

        how = state["continuing"] ? "continuing its session #{cut['session_id']}" : "from its first prompt, in the same worktree"
        AgentSession.note(run, "[harbor] started again after the interruption (#{cut['reason']}): #{how}")
      end

      def unclaim(run, error)
        said = run.with_lock do
          state = run.runner_state.to_h.deep_dup
          cut = state["interrupted"]
          next true if cut.blank?
          before = cut["error"]
          state["interrupted"] = cut.except("starting_at").merge("error" => error.message)
          run.update_columns(runner_state: state)
          before == error.message
        end
        Rails.logger.error("[harbor] run #{run.id}: could not start the interrupted session again: #{error.class}: #{error.message}")
        # Said once in the run's log for each different reason, not every minute.
        AgentSession.note(run, "[harbor] could not start it again yet (#{error.message}); trying again every minute") unless said
      rescue StandardError => e
        Rails.logger.error("[harbor] run #{run.id}: #{e.class}: #{e.message}")
      end

      def give_up(run, _expired)
        cut = run.runner_state.to_h["interrupted"].to_h
        why = cut["error"].present? ? ": #{cut['error']}" : "."
        Finisher.call(run, error: "The session was interrupted (#{cut['reason']}) and could not be started again " \
                                  "within #{WINDOW.inspect}#{why}")
        nil
      end
    end
  end
end
