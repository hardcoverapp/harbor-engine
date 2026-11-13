module Harbor
  # An agent session: one run of an AI coding agent's command line (`claude
  # -p`, or `codex exec`) as a command in a terminal on a runtime, with only
  # HTTP between that machine and this app.
  #
  #   run = Harbor::AgentSession.run!(agent: agent, prompt: "Fix the failing test in …")
  #
  # Harbor builds the command (Command), wraps it in the runner script
  # (Harbor::Runner) and asks the runtime's backend to start it. The script
  # fetches the run's prompt, MCP config and environment over HTTPS, runs the
  # command, and posts what it prints back. Harbor keeps those bytes as the
  # run's raw stream, reads them as they arrive into the live log and the
  # run's events (Recorder), and when the command ends writes the session,
  # cost, tokens, final text and status on the run (Finisher).
  #
  # What Harbor keeps about a session while it runs is in the run's
  # `runner_state`:
  #
  #   "cli", "provider"       the command line in use and whose model it runs
  #   "attempt"               1, or 2 once it was started again without --resume
  #   "received", "digested"  bytes of output taken, and how far lines were read
  #   "raw_base"              where this attempt starts in the raw stream file
  #   "seq"                   the last event number used
  #   "session"               the worktree and terminal, as the backend gave them
  #   "last_seen_at"          when the runner last sent anything
  #   "timeout_at", "idle_timeout"
  #   "stop_reason", "stop_note"   why Harbor stopped it, when it did
  #   "slots"                 the capacity slots to give back at the end
  #   "keep_worktree", "resume_session_id", "resume_fallback"
  #   "exit_status", "signalled"   what the runner reported
  #
  # The prompt, system prompt and MCP config are kept in the run's input
  # (`input["agent_session"]`) for the runner to fetch. Secrets are in none of
  # these: they come from `config.agent_session_env` when the runner asks.
  module AgentSession
    class Error < StandardError; end
    # start! was called for a run that is already a session, or is over.
    class AlreadyStarted < Error; end

    # The files a session's runner fetches before the command starts.
    BUNDLE = %w[prompt system mcp env].freeze
    # A session always gets an MCP config of its own, if only an empty one.
    EMPTY_MCP = { "mcpServers" => {} }.freeze
    STOP_REASONS = %w[canceled timeout].freeze
    DEFAULT_TIMEOUT = 30.minutes
    # A slot outlives the session's timeout by this much, so it is given back
    # by the finisher and not by expiring under a session still being stopped.
    SLOT_MARGIN = 10.minutes

    # Told to every agent, after its own prompt.
    UNATTENDED = <<~TEXT.squish.freeze
      This is an unattended run, started by an automated system and not from a person's terminal. Nobody is
      watching and there is no next turn: when you end your turn the process exits and the run is recorded as
      finished. Never ask a question, never wait for confirmation or any other input, and never end your turn
      to wait for something still running in the background. If something you need is missing or a
      precondition fails, print a line starting with ERROR: that says what, and exit non-zero.
    TEXT

    class << self
      # Starts a session for a run that has somewhere to go: `runtime` and
      # `choice` (a model choice) as placement returned them. Returns the run
      # at once, running; the session reports as it goes. A session that
      # can't be started is finished as an error, and the run still returned.
      #
      #   allowed_tools, permission_mode   the agent's own unless given
      #   mcp_config        { "mcpServers" => { … } }; kept with the run, so
      #                     no secrets in it (put them in the environment)
      #   resume_session_id continue an earlier session of the same CLI
      #   base              the branch the worktree starts from
      #   timeout           how long the session may take in all
      #   idle_timeout      how long it may print nothing
      #   keep_worktree     leave the worktree when the session ends
      #   slots             capacity slots to give back at the end (run! passes them)
      def start!(run:, agent:, prompt:, runtime:, choice:, system_prompt_extra: nil, allowed_tools: :agent,
                 disallowed_tools: nil, permission_mode: :agent, add_dirs: [], mcp_config: nil, resume_session_id: nil,
                 base: nil, timeout: DEFAULT_TIMEOUT, idle_timeout: nil, keep_worktree: false, slots: nil)
        Starter.new(run:, agent:, prompt:, runtime:, choice:, system_prompt_extra:, allowed_tools:, disallowed_tools:,
                    permission_mode:, add_dirs:, mcp_config:, resume_session_id:, base:, timeout:, idle_timeout:,
                    keep_worktree:, slots:).call
      end

      # Runs an agent: makes the run, finds it a runtime and a model through
      # the agent's workspace, takes a slot on the runtime and one of the
      # agent's, and starts the session. `options` are start!'s.
      #
      # When the agent or every usable runtime is full, or no model is
      # available, nothing is started: what was taken is given back and the
      # run is returned still waiting (`queued`, or `waiting_for_model`) with
      # the reason in its log. Trying again later is the caller's.
      #
      #   run           a run made earlier (one that waited), instead of a new one
      #   attributes    for the new run: skill, task_type, trigger_source, subject…
      #   requirements  placement's, such as { tool_policy: true }
      def run!(agent:, prompt:, run: nil, attributes: {}, requirements: {}, **options)
        run ||= Harbor.run_class.create!({ agent_key: agent.key, status: "queued" }.merge(attributes))
        owner = "run:#{run.id}"
        ttl = (options.fetch(:timeout, DEFAULT_TIMEOUT) || 1.day).to_i + SLOT_MARGIN.to_i

        agent_slot = Harbor::Slots.acquire(agent, owner, ttl:)
        return wait!(run, "queued", "#{agent.display_name} is already running as many sessions as it may.") if agent_slot.nil?

        policy = options.slice(:allowed_tools, :disallowed_tools)
        policy.delete(:allowed_tools) if policy[:allowed_tools] == :agent
        begin
          placement = agent.placement(run:, capacity: { owner:, ttl:, workspace: nil }, requirements:, **policy)
        rescue *unavailable_errors => e
          Harbor::Slots.release(agent.key, agent_slot, owner)
          return wait!(run, "waiting_for_model", e.message)
        end
        if placement.waiting?
          Harbor::Slots.release(agent.key, agent_slot, owner)
          return wait!(run, "queued", "Every runtime that could take this is full: #{placement.summary}")
        end

        note(run, "[harbor] #{placement.summary}")
        slots = { "owner" => owner, "agent" => { "key" => agent.key, "slot" => agent_slot },
                  "runtime" => { "key" => placement.runtime.key, "slot" => placement.slot } }
        start!(run:, agent:, prompt:, runtime: placement.runtime, choice: placement.choice, slots:, **options)
      end

      # Stops a session: records why, closes its terminal, and finishes the
      # run without waiting for a result that may never come. Safe to call
      # twice, and on a run that is already over. `reason` becomes the run's
      # status: "canceled" or "timeout".
      def stop!(run, reason: "canceled", note: nil)
        raise ArgumentError, "a session is stopped as #{STOP_REASONS.join(' or ')}, not #{reason.inspect}" unless STOP_REASONS.include?(reason.to_s)

        recorded = run.with_lock do
          next false if run.finished?
          state = run.runner_state.to_h
          # The first reason given is the one that stands.
          run.update_columns(runner_state: state.merge("stop_reason" => reason.to_s, "stop_note" => note)) if state["stop_reason"].blank?
          true
        end
        return run unless recorded

        session = session_of(run)
        if session
          begin
            backend_for(run)&.stop(session)
          rescue StandardError => e
            # The run is finished all the same; the runner stops its command
            # when it is told the run is over.
            log_failure(run, "closing the terminal", e)
          end
        end
        Finisher.call(run)
      end

      # Whether a run is an agent session (started by start!).
      def session?(run) = run.runner_state.to_h["cli"].present?

      # The backend that drives a runtime's sessions.
      def backend(runtime)
        adapter = runtime.adapter
        return adapter if %i[start restart stop cleanup exited?].all? { |action| adapter.respond_to?(action) }
        raise Error, "#{runtime.name} can't run agent sessions: its backend (#{runtime.backend}) doesn't start commands."
      end

      # The backend of the runtime a run was placed on, or nil.
      def backend_for(run)
        runtime = run.runtime_id && Harbor.runtime_class.find_by(id: run.runtime_id)
        runtime && backend(runtime)
      end

      # What the run holds on its runtime (worktree, terminal), or nil.
      def session_of(run)
        held = run.runner_state.to_h["session"]
        Harbor::Runtimes::Backends::Orca::Session.from(held) if held.present?
      end

      # One of the files a session's runner fetches, by name; nil for a name
      # that isn't one. `env` is worked out now, from the host's hook.
      def bundle_file(run, name)
        kept = run.input.to_h["agent_session"].to_h
        case name.to_s
        when "prompt" then kept["prompt"].to_s
        when "system" then kept["system"].to_s
        when "mcp" then JSON.generate(kept["mcp"].presence || EMPTY_MCP)
        when "env" then Environment.file(run, run.runner_state.to_h["provider"])
        end
      end

      # When the session's runner last sent anything; before that, when the
      # session started.
      def last_heard(run)
        seen = run.runner_state.to_h["last_seen_at"]
        (seen.present? && Time.zone.parse(seen)) || run.started_at || run.created_at
      end

      # Where a run's raw stream is kept: beside its live log.
      def raw_log_path(run)
        live = run.live_log_path
        live.present? ? "#{live.sub(/\.[^.\/]*\z/, '')}.ndjson" : "agent-sessions/run-#{run.id}.ndjson"
      end

      # A line of Harbor's own in the run's live log.
      def note(run, text) = Harbor::LiveLog.append(run.live_log_path, "#{text}\n")

      def log_failure(run, what, error)
        Rails.logger.error("[harbor] run #{run.id}: #{what} failed: #{error.class}: #{error.message}")
        note(run, "[harbor] #{what} failed: #{error.message}") rescue nil
      end

      private

      def wait!(run, status, reason)
        run.update!(status:) unless run.status == status
        note(run, "[harbor] waiting: #{reason}")
        run
      end

      # Each configured class may define an Unavailable of its own.
      def unavailable_errors
        [ Harbor::ModelAlias::Unavailable, Harbor.model_alias_class::Unavailable, Harbor.workspace_profile_class::Unavailable ].uniq
      end
    end
  end
end
