module Harbor
  module ConductorCloud
    # One look at an agent session running in a Conductor Cloud workspace
    # (Harbor::AgentSession::PollJob calls it every few seconds, through the
    # runtime's backend). Nothing there reports to Harbor, so Harbor asks:
    #
    #   setup     the workspace is still getting ready (its setup script runs
    #             first). Only its status is asked. The run's own clock has
    #             not started; setup has a limit of its own (a setting).
    #   command   the session is working. New transcript messages are read
    #             and recorded exactly as an agent command's output is
    #             (Harbor::AgentSession::Recorder), then the session's status
    #             is asked. The run is finished when the transcript holds the
    #             agent's result, when the session goes idle after working,
    #             or when it reports an error.
    #
    # What it needs between looks is on the run, so the next look can be made
    # by any process, after any restart:
    #
    #   runner_state["conductor"]   "phase", "since" (when the phase began),
    #                               "last_message_id" (the read position),
    #                               "working" (the session was seen working),
    #                               "ended", "error", "last_text" (how the
    #                               agent's turn ended, once it has),
    #                               "announced", "api_down_since"
    #
    # Conductor's API being briefly unavailable (a 5xx, a timeout) says
    # nothing about the session, which keeps working: that look is skipped,
    # said once in the run's log, and the next one asks again. The run's own
    # timeout still bounds the wait.
    class SessionPoll
      # A workspace that can be worked in.
      READY = %w[ready sleeping].freeze
      # Idle without ever having worked for this long: the first message was
      # never delivered.
      NEVER_STARTED_AFTER = 15.minutes

      Client = Harbor::ConductorCloud::Client

      def initialize(run, backend:)
        @run = run
        @backend = backend
      end

      # Seconds until the next look, or nil when the run is over.
      def call
        return nil unless @run.running?
        # Being started, or cut off and about to be started again
        # (Harbor::AgentSession::Interruption): there is nothing to ask yet.
        return interval if Harbor::AgentSession::Interruption.interrupted?(@run)
        @session = Harbor::AgentSession.session_of(@run) or return interval

        progress["phase"] == "command" ? follow : setup
        @run.reload.running? ? interval : nil
      rescue Client::Unavailable, Client::MissingKey => e
        unavailable(e)
        interval
      rescue Client::Error => e
        # Anything else Conductor refuses (an unknown session, a key it won't
        # take) is not going to get better by asking again.
        finish(error: "Conductor refused: #{e.message}")
        nil
      end

      private

      def client = @backend.client

      def interval = Harbor::Setting.get(:conductor_cloud_poll_seconds).to_i.clamp(1, 3600)

      def setup_limit = Harbor::Setting.get(:conductor_cloud_setup_minutes).to_i.minutes

      def progress = @run.runner_state.to_h["conductor"].to_h

      def name = @session.name.presence || @session.workspace_id

      def note(text) = Harbor::AgentSession.note(@run, "[conductor] #{text}")

      # --- setup ---

      def setup
        status = client.workspace_status(@session.workspace_id)
        answered
        stage = status["status"].to_s
        return begin_command if READY.include?(stage)
        return finish(error: "The Conductor Cloud workspace #{name} is #{stage}.") if Harbor::Runtimes::Backends::ConductorCloud::GONE.include?(stage)
        return finish(error: "The Conductor Cloud workspace #{name} could not be set up: #{status['errorMessage']}") if status["errorMessage"].present?

        since = Time.zone.parse(progress["since"].to_s) || @run.started_at || Time.current
        if Time.current - since > setup_limit
          return finish(error: "The Conductor Cloud workspace #{name} wasn't ready after #{(setup_limit / 60).to_i} minutes of setup.")
        end

        first = update { |state, mine| waiting(state); mine["announced"] ? false : (mine["announced"] = true) }
        note("waiting for #{name} to finish setting up (#{status['lifecycleStep'].presence || stage})") if first
      end

      # The workspace is ready and its session has the message. The run's own
      # clock starts now.
      def begin_command
        update do |state, mine|
          waiting(state)
          mine.merge!("phase" => "command", "since" => Time.current.iso8601)
          mine.delete("announced")
        end
        note("#{name} is ready; following its session")
        follow
      end

      # Time spent waiting for a workspace is not the session's: its time
      # limit is counted from now, and it has not been quiet.
      def waiting(state)
        now = Time.current
        state["timeout_at"] = (now + state["timeout"].to_i).iso8601 if state["timeout"].present? && state["timeout_at"].present?
        state["alive_at"] = state["last_seen_at"] = now.iso8601
      end

      # --- command ---

      def follow
        pull
        return finish_from_transcript if progress["ended"].present?

        status = client.session_status(@session.session_id)
        answered
        case status["status"].to_s
        when "working"
          update { |_, mine| mine["working"] = true } unless progress["working"]
        when "error"
          finish(error: "The Conductor Cloud session failed: #{status['errorMessage'].presence || status['lastError'].presence || 'it reported an error'}")
        when "idle"
          if progress["working"]
            # What it wrote between the last read and going idle.
            pull
            finish_from_transcript
          elsif Time.current - (Time.zone.parse(progress["since"].to_s) || Time.current) > NEVER_STARTED_AFTER
            finish(error: "The Conductor Cloud session never started working: its first message was not delivered.")
          end
        end
      end

      # Reads every transcript message after the read position and records
      # them. Two looks at once can't record the same message twice: the
      # second finds the position moved and drops what it read.
      def pull
        after = progress["last_message_id"]
        messages = []
        cursor = after
        loop do
          page = client.messages(@session.session_id, after: cursor)
          rows = Array(page["data"])
          messages.concat(rows)
          cursor = rows.last["id"] if rows.any?
          break unless page["hasMore"] && rows.any?
        end
        answered
        return if messages.empty?

        read = Transcript.read(messages)
        @run.with_lock do
          next if @run.finished?
          state = @run.runner_state.to_h.deep_dup
          mine = state["conductor"].to_h
          next unless mine["last_message_id"] == after

          recorder = Harbor::AgentSession::Recorder.new(@run, state)
          recorder.append(read.bytes) if read.bytes.bytesize.positive?
          now = Time.current.iso8601
          state["alive_at"] = now
          state["last_seen_at"] = now if read.bytes.bytesize.positive?
          mine["last_message_id"] = cursor
          # The agent wrote something, so it has worked, however briefly.
          mine["working"] = true if read.bytes.bytesize.positive?
          mine.merge!("ended" => read.ended, "error" => read.error) if read.ended
          mine["last_text"] = read.last_text if read.last_text
          state["conductor"] = mine.compact
          @run.update_columns(recorder.columns.merge(runner_state: state))
        end
      end

      # The agent's turn is over. Its own result decides: a successful one is
      # exit 0 to the finisher, which then reads cost, tokens and the final
      # text from the recorded stream, as it does for a command that ended.
      def finish_from_transcript
        mine = progress
        return Harbor::AgentSession::Finisher.call(@run, exit_status: 0) if mine["ended"] == "ok"
        finish(exit_status: 1, error: mine["error"].presence || mine["last_text"].presence || "The agent ended without a successful result.")
      end

      def finish(error:, exit_status: nil)
        note("ERROR: #{error}")
        Harbor::AgentSession::Finisher.call(@run, exit_status:, error:)
      end

      # --- bookkeeping ---

      # Changes the run's state under its lock. The block is given the whole
      # runner state and this poll's part of it, and its value is returned.
      def update
        @run.with_lock do
          next nil if @run.finished?
          state = @run.runner_state.to_h.deep_dup
          mine = state["conductor"].to_h
          result = yield state, mine
          state["conductor"] = mine
          @run.update_columns(runner_state: state)
          result
        end
      end

      # Conductor answered: the session was asked about, which is all a
      # session with no runner can say for being there.
      def answered
        return if @answered
        @answered = true
        down = update do |state, mine|
          state["alive_at"] = Time.current.iso8601
          mine.delete("api_down_since")
        end
        note("Conductor's API is answering again after #{(Time.current - Time.zone.parse(down)).round}s") if down.present?
      end

      def unavailable(error)
        first = update { |_, mine| mine["api_down_since"] ? false : (mine["api_down_since"] = Time.current.iso8601) }
        note("#{error.message}; still following the session") if first
      rescue StandardError => e
        Rails.logger.error("[harbor] run #{@run.id}: #{e.class}: #{e.message}")
      end
    end
  end
end
