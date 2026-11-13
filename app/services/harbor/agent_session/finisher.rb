module Harbor
  module AgentSession
    # Ends a session, whichever way it ended: the runner reported a result,
    # Harbor stopped it, it ran out of time, or its runner went away. It can
    # be called any number of times and from any of those at once; the run's
    # row lock lets exactly one call finish the run, and only that call
    # cleans up and tells the host.
    #
    #   Finisher.call(run, exit_status: 0)               the runner's report
    #   Finisher.call(run)                               after a stop
    #   Finisher.call(run, error: "the runner stopped…") Harbor's own verdict
    class Finisher
      TEXT_CAP = 2_000

      def self.call(run, **options) = new(run, **options).call

      def initialize(run, exit_status: nil, signalled: false, error: nil)
        @run = run
        @exit_status = exit_status
        @signalled = signalled
        @error = error
      end

      def call
        case settle
        when :finished then put_away
        when :again then start_again
        end
        @run
      end

      private

      # Under the run's lock: read what is left of the output, then either
      # finish the run or decide it gets one more attempt.
      def settle
        @run.with_lock do
          next nil if @run.finished?

          @state = @run.runner_state.to_h.deep_dup
          recorder = Recorder.new(@run, @state)
          guarded("reading the last of the output") { recorder.finish }
          stream = guarded("reading the stream") { read_stream } || Stream.new

          if start_again?(stream)
            @state.merge!("attempt" => @state["attempt"].to_i + 1, "received" => 0, "digested" => 0,
                          "raw_base" => raw_size, "resume_fallback" => true)
            @run.update_columns(runner_state: @state)
            next :again
          end

          @state["exit_status"] = @exit_status unless @exit_status.nil?
          @state["signalled"] = true if @signalled
          status, error = verdict(stream)
          @run.assign_attributes(columns(stream).merge(runner_state: @state))
          @run.finish!(status:, output: output(stream), error:)
          :finished
        end
      end

      def cli = @state["cli"].presence || "the agent"

      def raw_file = @run.raw_log_path.present? ? Harbor::LiveLog.absolute(@run.raw_log_path) : nil

      def raw_size = raw_file && File.file?(raw_file) ? File.size(raw_file) : 0

      # This attempt's whole stream, read from the file: the record of what
      # the session cost and said.
      def read_stream
        stream = Stream.new
        return stream unless raw_file && File.file?(raw_file)

        File.open(raw_file, "rb") do |file|
          file.seek(@state["raw_base"].to_i)
          file.each_line { |line| stream.feed(line.force_encoding(Encoding::UTF_8).scrub("?")) }
        end
        stream
      end

      # A reason Harbor recorded for stopping the session wins over anything
      # the command reported; then Harbor's own verdict; then the exit
      # status. An error result in the stream does not fail a run that
      # exited 0: it is kept as the run's error class.
      def verdict(stream)
        reason = @state["stop_reason"].presence
        return [ reason, @state["stop_note"].presence ] if reason
        return [ "error", @error ] if @error
        return [ "ok", nil ] if @exit_status == 0
        return [ "error", "#{cli} ended without reporting how." ] if @exit_status.nil?
        [ "error", stream.plain_tail.last(TEXT_CAP).presence || "#{cli} exited #{@exit_status}" ]
      end

      def output(stream)
        { "exit_code" => @exit_status,
          "text" => stream.summary.final_text.presence || stream.plain_tail.last(TEXT_CAP).presence }.compact
      end

      def columns(stream)
        summary = stream.summary
        # A run moved to another model part-way keeps, with each move, the
        # usage up to then. This attempt's totals are added to the last of
        # those, once, however often the run is reconciled.
        before = Array(@run.input.to_h["model_switches"]).last.to_h["usage"].to_h
        { session_id: summary.session_id.presence || @run.session_id,
          model: summary.model.presence || @run.model,
          cost_usd_actual: cumulative(before["cost_usd_actual"], summary.cost_usd),
          duration_ms: cumulative(before["duration_ms"], summary.duration_ms),
          input_tokens: cumulative(before["input_tokens"], summary.input_tokens),
          output_tokens: cumulative(before["output_tokens"], summary.output_tokens),
          cache_read_tokens: cumulative(before["cache_read_tokens"], summary.cache_read_tokens),
          cache_creation_tokens: cumulative(before["cache_creation_tokens"], summary.cache_creation_tokens),
          error_class: summary.success? ? nil : summary.result_subtype.presence }
      end

      def cumulative(previous, current)
        return current if previous.nil?
        return previous if current.nil?
        previous.to_f + current
      end

      # One more attempt, once, when continuing an earlier session failed
      # before the agent did anything (ResumeFallback): otherwise a pruned
      # session would lose the whole piece of work.
      def start_again?(stream)
        @state["resume_session_id"].present? && !@state["resume_fallback"] && @state["stop_reason"].blank? &&
          @error.nil? && !@exit_status.nil? && !@signalled && @state["session"].present? &&
          ResumeFallback.failed?(exit_status: @exit_status, turns: stream.summary.result_turns)
      end

      # The same command without --resume, in a new terminal of the same
      # worktree. The run stays running throughout.
      def start_again
        backend = AgentSession.backend_for(@run)
        held = Harbor::Runtimes::Backends::Orca::Session.from(@state["session"])
        kept = @run.input.to_h["agent_session"].to_h
        AgentSession.note(@run, "[harbor] --resume #{@state['resume_session_id']} did not continue " \
                                "(exit #{@exit_status}); starting again without it")
        guarded("closing the first terminal") { backend.stop(held) }
        command = Command.from(kept["command"], mcp_config: kept["mcp"]).without_resume
        fresh = backend.restart(held, run: @run, command: command.shell, bundle: command.bundle, attempt: @state["attempt"])

        over = @run.with_lock do
          next true if @run.finished?
          @run.update_columns(command: command.display, runner_state: @run.runner_state.to_h.merge("session" => fresh.to_h))
          false
        end
        # Stopped in the meantime: the new terminal has nothing to do.
        guarded("closing the new terminal") { backend.stop(fresh) } if over
      rescue StandardError => e
        Rails.logger.error("[harbor] run #{@run.id}: could not start again without --resume: #{e.class}: #{e.message}")
        self.class.call(@run, exit_status: @exit_status, error: "Continuing the earlier session failed, and so did starting again without it: #{e.message}")
      end

      # After the run is finished. Each step stands alone: one that fails is
      # logged and the rest still happen, and the run stays finished.
      def put_away
        guarded("giving back its slots") { release_slots }
        session = AgentSession.session_of(@run)
        backend = session && guarded("finding its runtime") { AgentSession.backend_for(@run) }
        if backend
          # A terminal whose command has ended stays open until it is closed.
          guarded("closing the terminal") { backend.stop(session) }
          guarded("removing the worktree") { backend.cleanup(session) } unless @state["keep_worktree"]
        end
        guarded("ending the log") do
          Harbor::LiveLog.append(@run.live_log_path, "\n<!-- run finished at #{Time.current.iso8601}: #{@run.status} -->\n")
        end
        guarded("the host's follow-up (agent_session_finished)") { Harbor.config.agent_session_finished&.call(@run) }
      end

      def release_slots
        slots = @state["slots"].to_h
        owner = slots["owner"]
        Harbor::Runtimes::Slots.release(slots.dig("runtime", "key"), slots.dig("runtime", "slot"), owner)
        Harbor::Slots.release(slots.dig("agent", "key"), slots.dig("agent", "slot"), owner)
      end

      def guarded(what)
        yield
      rescue StandardError => e
        AgentSession.log_failure(@run, what, e)
        nil
      end
    end
  end
end
