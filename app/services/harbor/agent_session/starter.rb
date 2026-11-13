module Harbor
  module AgentSession
    # Starts one session (Harbor::AgentSession.start!): marks the run running
    # with everything the runner will ask for, has the backend start the
    # wrapped command, and schedules the checks that end a session that
    # overruns or goes quiet.
    class Starter
      def initialize(run:, agent:, prompt:, runtime:, choice:, system_prompt_extra:, allowed_tools:, disallowed_tools:,
                     permission_mode:, add_dirs:, mcp_config:, resume_session_id:, base:, timeout:, idle_timeout:,
                     keep_worktree:, slots:)
        @run = run
        @agent = agent
        @prompt = prompt.to_s
        @runtime = runtime
        @choice = choice
        @system_prompt_extra = system_prompt_extra
        @allowed_tools = allowed_tools == :agent ? agent.tools.to_h["allowed"] : allowed_tools
        @disallowed_tools = disallowed_tools
        @permission_mode = permission_mode == :agent ? agent.tools.to_h["permission_mode"] : permission_mode
        @add_dirs = add_dirs
        @mcp_config = mcp_config.presence
        @resume_session_id = resume_session_id
        @base = base
        @timeout = timeout&.to_i
        @idle_timeout = idle_timeout&.to_i
        @keep_worktree = keep_worktree
        @slots = slots
      end

      def call
        session = nil
        backend = AgentSession.backend(@runtime)
        command = build_command
        claim(backend, command)
        session = backend.start(run: @run, command: command.shell, base: @base, title: title, bundle: BUNDLE, attempt: 1)
        keep(session)
        schedule
        @run
      rescue AlreadyStarted
        raise
      rescue StandardError => e
        fail!(e, session)
      end

      private

      def build_command
        Command.new(cli: Command.cli_for(@choice), model: @choice.model, effort: @choice.effort,
                    permission_mode: @permission_mode, allowed_tools: @allowed_tools, disallowed_tools: @disallowed_tools,
                    add_dirs: @add_dirs, mcp_config: @mcp_config, resume_session_id: @resume_session_id)
      end

      # What the agent is told before its task: its own instructions, that
      # nobody is there to answer it, the site's line, then the caller's.
      def system_prompt
        [ @agent.full_system_prompt, UNATTENDED, Harbor.config.agent_session_preamble&.call(@run),
          @system_prompt_extra ].compact_blank.join("\n\n")
      end

      def title = "#{@agent.display_name} · run #{@run.id}"

      def claim(backend, command)
        @run.with_lock do
          raise AlreadyStarted, "Run #{@run.id} is already over (#{@run.status})." if @run.finished?
          raise AlreadyStarted, "Run #{@run.id} is already an agent session." if AgentSession.session?(@run)

          now = Time.current
          @run.assign_attributes(
            status: "running", started_at: @run.started_at || now, agent_key: @run.agent_key.presence || @agent.key,
            model: @choice.model, effort: @choice.effort, executor: @runtime.backend, runner_name: backend.runner_name,
            runtime_id: @runtime.id, command: command.display,
            input: @run.input.to_h.merge("agent_session" => { "prompt" => @prompt, "system" => system_prompt,
                                                              "mcp" => @mcp_config, "command" => command.to_h }.compact),
            runner_state: state(command, now))
          # The log's name can depend on what was just set (the agent's key).
          @run.raw_log_path = AgentSession.raw_log_path(@run)
          @run.save!
        end
        Harbor::LiveLog.append(@run.live_log_path, "\n<!-- run started at #{Time.current.iso8601} -->\n\n")
        AgentSession.note(@run, "[harbor] #{command.display} · on #{backend.runner_name}")
      end

      def state(command, now)
        { "cli" => command.cli, "provider" => @choice.model_provider&.key, "attempt" => 1, "received" => 0, "digested" => 0,
          "raw_base" => 0, "seq" => @run.run_events.maximum(:seq).to_i, "last_seen_at" => nil,
          "timeout" => @timeout, "timeout_at" => (@timeout && (now + @timeout).iso8601), "idle_timeout" => @idle_timeout,
          "slots" => @slots, "keep_worktree" => @keep_worktree ? true : nil,
          "resume_session_id" => command.resume_session_id }.compact
      end

      def keep(session)
        @run.with_lock { @run.update_columns(runner_state: @run.runner_state.to_h.merge("session" => session.to_h)) }
      end

      def schedule
        WatchJob.set(wait: @timeout.seconds).perform_later(@run.id, "timeout") if @timeout
        WatchJob.set(wait: @idle_timeout.seconds).perform_later(@run.id, "idle") if @idle_timeout
        WatchJob.set(wait: Watch.silent_after).perform_later(@run.id, "silent")
      end

      # The session could not be started. Whatever exists by now is put away
      # by the finisher: the slots given back, a worktree removed.
      def fail!(error, session)
        Rails.logger.error("[harbor] run #{@run.id}: the agent session could not be started: #{error.class}: #{error.message}")
        @run.with_lock do
          held = @run.runner_state.to_h
          held["slots"] ||= @slots if @slots
          held["session"] ||= session.to_h if session
          @run.update_columns(runner_state: held)
        end
        Finisher.call(@run, error: "The agent session could not be started: #{error.message}")
      end
    end
  end
end
