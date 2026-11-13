module Harbor
  # What Harbor does with what a runner posts (Harbor::Runner): a piece of a
  # run's output, its result, or a request for one of its files. Each answer
  # is a Reply the controller sends as it is.
  #
  # A piece of output says where it starts (`offset`: how many bytes the
  # runner has had accepted). Harbor keeps count of what it has, so:
  #
  #   offset == received   the next piece: appended
  #   offset <  received   a piece sent again: the part already here is
  #                        dropped and the rest appended
  #   offset >  received   something is missing: refused with 409 and
  #                        Harbor's count, and the runner sends from there
  #
  # The bytes are kept exactly as they arrive. A run that was started more
  # than once (an agent session started again) counts from zero each time,
  # and a post from an earlier start is refused.
  module RunnerReport
    Reply = Struct.new(:status, :body, :content_type) do
      def self.none = new(:no_content)
      def self.refused(why) = new(:conflict, why.to_s, "text/plain")
    end

    FINISHED = "finished".freeze
    STALE = "stale".freeze

    module_function

    def log(run, bytes, offset: nil, attempt: nil)
      run.with_lock do
        next Reply.refused(FINISHED) if run.finished?
        next Reply.refused(STALE) if stale?(run, attempt)

        state = run.runner_state.to_h.deep_dup
        received = state["received"].to_i
        # A runner from before offsets says none: its piece is the next one.
        offset ||= received
        next Reply.refused(received) if offset > received

        fresh = bytes.byteslice(received - offset, bytes.bytesize).to_s
        columns = {}
        if fresh.bytesize.positive?
          if Harbor::AgentSession.session?(run)
            recorder = Harbor::AgentSession::Recorder.new(run, state)
            recorder.append(fresh)
            columns = recorder.columns
          else
            Harbor::LiveLog.append(run.live_log_path, fresh)
            state["received"] = received + fresh.bytesize
          end
        end
        state["last_seen_at"] = Time.current.iso8601
        run.update_columns(columns.merge(runner_state: state))
        Reply.none
      end
    end

    # The command ended. Reported once: a second report, a report from an
    # earlier start, or one for a run Harbor has already finished changes
    # nothing.
    def result(run, exit_status:, signalled: false, attempt: nil)
      return Reply.none if run.finished? || stale?(run, attempt)
      if Harbor::AgentSession.session?(run)
        Harbor::AgentSession::Finisher.call(run, exit_status:, signalled:)
        return Reply.none
      end

      first = run.with_lock do
        state = run.runner_state.to_h
        next false if run.finished? || state["reported"]
        run.update_columns(runner_state: state.merge("reported" => true, "exit_status" => exit_status,
                                                     "signalled" => signalled ? true : nil).compact)
        true
      end
      return Reply.none unless first

      if Harbor.config.run_reported
        Harbor.config.run_reported.call(run, exit_status: exit_status)
      else
        run.finish!(status: exit_status.zero? ? "ok" : "error",
                    error: (exit_status.zero? ? nil : "The command exited with status #{exit_status}."))
      end
      Reply.none
    end

    # One of the files an agent session's runner fetches before its command
    # starts, while the session is running and at no other time.
    def bundle(run, name, attempt: nil)
      return Reply.new(:not_found, "no such file", "text/plain") unless Harbor::AgentSession::BUNDLE.include?(name.to_s) &&
                                                                        Harbor::AgentSession.session?(run)
      return Reply.refused(FINISHED) unless run.running?
      return Reply.refused(STALE) if stale?(run, attempt)

      body = Harbor::AgentSession.bundle_file(run, name)
      Reply.new(:ok, body, name.to_s == "mcp" ? "application/json" : "text/plain")
    rescue Harbor::AgentSession::Environment::Invalid => e
      # Said in the run's log and to the runner: a name, never a value.
      Harbor::AgentSession.note(run, "[harbor] the session's environment was refused: #{e.message}")
      Reply.new(:unprocessable_entity, e.message, "text/plain")
    end

    # A post that names a start of the run other than the current one.
    def stale?(run, attempt)
      current = run.runner_state.to_h["attempt"]
      attempt.present? && current.present? && attempt.to_i != current.to_i
    end
  end
end
