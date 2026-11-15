module Harbor
  module Runtimes
    module Backends
      # Work in Conductor Cloud (https://www.conductor.build): a run is an
      # agent session in a cloud workspace Conductor makes for it from a
      # repository. There is no terminal and no runner script: creating the
      # workspace starts the agent on its first message, and Harbor follows
      # the session by asking Conductor's API (Harbor::ConductorCloud::SessionPoll).
      #
      # A runtime's config:
      #   "repository_url"  the repository Conductor clones (https://…)
      #   "branch"          the branch a workspace starts from; blank for the
      #                     repository's default. A session's own `base:` wins.
      #   "api_key_env"     the name of the environment variable that holds
      #                     the Conductor API key; CONDUCTOR_API_KEY when
      #                     blank. The key is a secret, so the config names
      #                     where it is, never the key.
      #   "api_url"         the API's address, when it isn't the public one
      #
      # The session side was built from Conductor's API documentation and
      # from a host's working use of the same calls, and tested against a
      # stand-in. It has not been run against the real service.
      class ConductorCloud < Harbor::Runtimes::Backend
        # What a started run holds in Conductor, to stop and clean up with.
        Session = Struct.new(:workspace_id, :session_id, :name, :deep_link, keyword_init: true) do
          def to_h = { "workspace_id" => workspace_id, "session_id" => session_id, "name" => name, "deep_link" => deep_link }.compact
          def self.from(hash) = new(workspace_id: hash["workspace_id"], session_id: hash["session_id"], name: hash["name"], deep_link: hash["deep_link"])
        end

        # Workspace states that mean it is not coming back.
        GONE = %w[archived deleted].freeze
        ENV_NAME = /\A[A-Z_][A-Z0-9_]*\z/
        # What Conductor says when a name (which is also the workspace's git
        # branch) is taken.
        NAME_TAKEN = /\b(name|branch|exist|conflict|409)\b/i

        class << self
          def label = "Conductor Cloud"

          def config_help
            "repository_url is the repository Conductor clones. branch is the branch a workspace starts from (the repository's default when left out). " \
              "api_key_env names the environment variable that holds the Conductor API key (CONDUCTOR_API_KEY when left out); the key itself is never typed here."
          end

          def config_example = { "repository_url" => "https://github.com/acme/app" }

          def choices(name)
            [ Harbor::Runtimes::Choice.new(value: name, backend: name, label: "Conductor Cloud",
                                           description: "Work runs in a Conductor Cloud workspace, made for each run from the repository.") ]
          end

          def fields_partial = "harbor/runtimes/conductor_cloud_fields"

          # A repository address the form starts from, for a host whose site
          # has one repository. nil: the field starts empty.
          def default_repository_url = nil

          # A line the form shows above the fields, for a host with something
          # to say about its Conductor runtimes. nil: nothing.
          def form_note = nil

          def settings_from(fields, choice:, **)
            repository = fields[:repository_url].to_s.strip
            raise ArgumentError, "Give the address of the repository Conductor clones." if repository.blank?
            raise ArgumentError, "The repository's address starts with https://, like https://github.com/acme/app." unless repository.match?(%r{\Ahttps://\S+\z})
            key = fields[:api_key_env].to_s.strip.presence
            if key && !key.match?(ENV_NAME)
              raise ArgumentError, "The API key is named by an environment variable, like #{Harbor::ConductorCloud::Client::DEFAULT_KEY_NAME}, not typed here."
            end
            address = fields[:api_url].to_s.strip.chomp("/").presence
            raise ArgumentError, "The API's address starts with https://." if address && !address.match?(%r{\Ahttps?://\S+\z})
            config = { "repository_url" => repository, "branch" => fields[:branch].to_s.strip.presence,
                       "api_key_env" => (key unless key == Harbor::ConductorCloud::Client::DEFAULT_KEY_NAME),
                       "api_url" => (address unless address == Harbor::ConductorCloud::Client::DEFAULT_URL) }
            { "config" => config.compact, "host" => nil }
          end

          # A session keeps its workspace when asked to (keep_worktree), so
          # follow-up work goes back to the runtime that holds it.
          def keeps_workspaces? = true

          # Conductor starts the agent with its own settings: Harbor has no
          # way to pass an allow or deny list, so none is enforced here.
          def enforces_tool_policy? = false

          # A model Conductor has (Harbor::ConductorCloud::Models).
          def supports?(choice, allowed_tools: nil, disallowed_tools: nil) = model_id_for(choice.model).present?

          # Conductor's id for a model, or nil. A host with its own naming
          # overrides this in a subclass.
          def model_id_for(model) = Harbor::ConductorCloud::Models.id_for(model)

          # Whether Harbor's agent sessions run on runtimes of this backend. A
          # host that drives Conductor its own way in a subclass, and wants no
          # session of Harbor's placed there, says false.
          def agent_sessions? = true
        end

        def place = repository_name

        def unready_reason
          return "the Conductor API key isn't set (#{api_key_env})" if api_key.blank?
          "no repository set" if repository_url.blank?
        end

        # One cheap read-only call: raises unless the API answers and takes
        # the key.
        def health_check
          raise "the Conductor API key isn't set (#{api_key_env})" if api_key.blank?
          client.sections(limit: 1)
        end

        def runner_name = runtime.name

        def repository_url = runtime.config["repository_url"].to_s.strip.presence
        def branch = runtime.config["branch"].to_s.strip.presence
        def api_key_env = runtime.config["api_key_env"].to_s.strip.presence || Harbor::ConductorCloud::Client::DEFAULT_KEY_NAME
        def api_url = runtime.config["api_url"].to_s.strip.presence || Harbor::ConductorCloud::Client::DEFAULT_URL

        # "acme/app", from https://github.com/acme/app.
        def repository_name
          address = repository_url or return nil
          URI.parse(address).path.to_s.delete_prefix("/").delete_suffix("/").delete_suffix(".git").presence || address
        rescue URI::InvalidURIError
          address
        end

        def client
          options[:client] || (@client ||= Harbor::ConductorCloud::Client.new(api_key:, base_url: api_url, key_name: api_key_env))
        end

        # --- agent sessions (Harbor::AgentSession) ---

        def agent_sessions? = self.class.agent_sessions?

        # A session here is followed by asking: Harbor::AgentSession::PollJob
        # calls this until the run is over. Returns how long until the next
        # look, in seconds, or nil when there is nothing more to follow.
        def poll_session(run) = Harbor::ConductorCloud::SessionPoll.new(run, backend: self).call

        # An earlier session's conversation lives in its workspace, which is
        # gone by the time another run could continue it.
        def continues_sessions? = false

        def session_from(hash) = Session.from(hash)

        def workspace_name(run, attempt = 1) = attempt.to_i > 1 ? "harbor-run-#{run.id}-#{attempt}" : "harbor-run-#{run.id}"

        # Makes a workspace for the run, whose first session starts at once
        # on the run's prompt. Returns the Session; nothing reports by itself,
        # so the run is followed by poll_session. What Harbor's own caller
        # passes for a terminal (`command`, `title`, `bundle`) has no use
        # here: the prompt and the model are read from the run.
        def start(run:, base: nil, attempt: 1, **)
          state = run.runner_state.to_h
          kept = run.input.to_h["agent_session"].to_h
          model = self.class.model_id_for(kept.dig("command", "model") || run.model)
          raise Harbor::AgentSession::Error, "Conductor Cloud has no model for #{kept.dig('command', 'model') || run.model}." if model.blank?
          agent = state["cli"].presence || "claude"
          effort = Harbor::ConductorCloud::Models.effort_for(kept.dig("command", "effort"))
          from = base.presence || branch

          name = workspace_name(run, attempt)
          create = lambda do |named|
            client.create_workspace(repository_url:, branch: from, name: named, agent:, model:, effort:,
                                    message: first_message(run), env: Harbor::AgentSession::Environment.for(run, state["provider"]))
          end
          created = begin
            create.call(name)
          rescue Harbor::ConductorCloud::Client::Unavailable
            raise
          rescue Harbor::ConductorCloud::Client::Error => e
            raise unless e.message.match?(NAME_TAKEN)
            create.call(name = "#{name}-#{SecureRandom.hex(2)}")
          end

          session = Session.new(workspace_id: created["workspaceId"], session_id: created["sessionId"], name:, deep_link: created["deepLink"])
          begin
            begun(run, session, agent:, model:, effort:, from:)
          rescue StandardError
            client.archive_workspace(session.workspace_id) rescue nil
            raise
          end
          session
        end

        # A session is not started again inside its workspace: the workspace
        # is put away and the run starts over in a new one.
        def restart(session, run:, **options)
          clear(session)
          start(run:, **options)
        end

        # Stops the session's current turn. False when Conductor no longer
        # has it.
        def stop(session)
          client.cancel_session(session.session_id)
          true
        rescue Harbor::ConductorCloud::Client::NotFound
          false
        end

        # Stops the session and archives its workspace. Always false: nothing
        # is left to start again in, so a run that goes on gets a new
        # workspace.
        def clear(session)
          stop(session)
          cleanup(session)
          false
        end

        # Archives a workspace made for the run that the run never recorded
        # (the app went down between making it and writing it down). False
        # when there is none.
        def discard(run)
          named = /\A#{Regexp.escape(workspace_name(run))}(-[A-Za-z0-9]+)*\z/
          found = []
          offset = 0
          loop do
            page = client.workspaces(name: workspace_name(run), repo: repository_url, offset:)
            rows = Array(page["data"])
            found += rows.select { |row| row["name"].to_s.match?(named) && !GONE.include?(row["state"].to_s) }
            break unless page["hasMore"] && rows.any?
            offset += rows.size
          end
          found.each { |row| client.archive_workspace(row["id"]) }
          found.any?
        end

        # Whether the session's workspace is gone for good. Harbor does not
        # ask this of a session it follows by polling; the poll finds it.
        def exited?(session)
          GONE.include?(client.workspace_status(session.workspace_id)["status"].to_s)
        rescue Harbor::ConductorCloud::Client::NotFound
          true
        end

        # Archives the run's workspace. False when Conductor no longer has it.
        def cleanup(session, **)
          client.archive_workspace(session.workspace_id)
          true
        rescue Harbor::ConductorCloud::Client::NotFound
          false
        end

        # The message the session starts on. Conductor has no separate system
        # prompt, so what the agent is told first (its own instructions, that
        # nobody is there, the site's line) goes ahead of the task in the one
        # message. A slash command is given as an instruction to read the
        # command's file and carry it out, from the ref it is read from when
        # one was given.
        def first_message(run)
          kept = run.input.to_h["agent_session"].to_h
          task = if (spec = kept.dig("command", "slash_command")).present?
            slash_command_message(Harbor::AgentSession::SlashCommand.new(spec, ref: kept.dig("command", "command_ref")))
          else
            kept["prompt"].to_s
          end
          [ kept["system"].presence, task ].compact.join("\n\n---\n\n")
        end

        private

        def api_key = ENV[api_key_env].presence

        def slash_command_message(command)
          read = command.ref ? "Read the file `#{command.path}` as it is at the git ref `#{command.ref}` (`git show #{command.ref}:#{command.path}`), not the copy checked out" : "Read the file `#{command.path}` in this repository"
          arguments = if command.arguments.any?
            "Where it says $ARGUMENTS use: #{command.arguments.join(' ')}. " \
              "Its positional arguments are: #{command.arguments.each_with_index.map { |argument, index| "$#{index + 1} = #{argument}" }.join(', ')}."
          else
            "It was given no arguments."
          end
          "#{read}, and carry out its instructions as your task. Ignore any YAML frontmatter at its top. #{arguments}"
        end

        # The run now has a workspace: its record says what really runs it,
        # and following starts from nothing read.
        def begun(run, session, agent:, model:, effort:, from:)
          now = Time.current
          run.with_lock do
            state = run.runner_state.to_h.deep_dup
            state["conductor"] = { "phase" => "setup", "since" => now.iso8601 }
            state["alive_at"] = now.iso8601
            command = [ agent, run.input.to_h.dig("agent_session", "command", "slash_command").presence || "<prompt…>",
                        "--model", model, *([ "--effort", effort ] if effort), "(Conductor Cloud)" ].join(" ")
            run.update_columns(command:, runner_state: state)
          end
          Harbor::AgentSession.note(run, "[conductor] workspace #{session.name}#{" on #{from}" if from} · #{agent} #{model} · #{session.deep_link}")
          ignored = run.input.to_h.dig("agent_session", "command").to_h.slice("allowed_tools", "disallowed_tools", "add_dirs").select { |_, value| value.present? }.keys
          ignored << "mcp_config" if run.input.to_h.dig("agent_session", "mcp").present?
          return if ignored.empty?
          Harbor::AgentSession.note(run, "[conductor] not applied here (Conductor starts the agent with its own settings): #{ignored.join(', ')}")
        end
      end
    end
  end
end
