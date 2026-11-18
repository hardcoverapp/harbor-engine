module Harbor
  module Runtimes
    module Backends
      # Work in Orca: a run is a command in an Orca terminal, in a worktree
      # Orca makes for it, wrapped so it reports its output and result back to
      # Harbor (Harbor::Runner). There are two kinds of Orca runtime:
      #
      # Orca: the worktree is a folder on the Orca server's own machine.
      #   "repo"       the Orca repo selector work happens in ("id:…",
      #                "name:app", "path:/code/app")
      #
      # Orca (Remote): the same Orca server makes the worktree on another
      # machine it reaches over SSH, and the run's command runs there.
      #   "host"       the Orca host ("ssh:<id>", as `orca host list` has it)
      #   "host_name"  that host's name, to show
      #   "project"    the Orca project (its id or name) to work in
      #   "provider"   who hosts the machine (PROVIDERS)
      #
      # Either kind:
      #   "setup"        whether the repo's own setup hooks run in a new
      #                  worktree: "run", "skip" (default) or "inherit"
      #   "environment"  another Orca server to ask, paired with this machine
      #                  (`orca environment add`); blank for the Orca here
      #   "pairing_code_env"  the name of the environment variable that holds
      #                  an Orca server's pairing code (orca://pair?…), for an
      #                  app that keeps no Orca pairing on disk (a container).
      #                  The code is a secret, so the config names where it
      #                  is, never the code. It wins over "environment".
      #
      # A pairing code can also be pasted on the runtime's page. It is then
      # the runtime's secret (Harbor::Runtime#secret): kept encrypted, used on
      # every command, never shown, and it wins over both of the above. That
      # is how an Orca server is added from the site, with no restart.
      #
      # The remote kind was built against Orca 1.4.257's commands
      # (`worktree create --project … --host ssh:…`) and has not yet been run
      # against a real remote host.
      class Orca < Harbor::Runtimes::Backend
        # What a started run holds on the server, to stop and clean up with.
        Session = Struct.new(:worktree_id, :worktree_path, :terminal, keyword_init: true) do
          def to_h = { "worktree_id" => worktree_id, "worktree_path" => worktree_path, "terminal" => terminal }
          def self.from(hash) = new(worktree_id: hash["worktree_id"], worktree_path: hash["worktree_path"], terminal: hash["terminal"])
        end

        # Who hosts a remote machine. More are added here as they are used.
        PROVIDERS = { "digitalocean" => "DigitalOcean" }.freeze
        SETUPS = { "skip" => "Skip them", "run" => "Run them", "inherit" => "As the repository says" }.freeze
        REMOTE = ":remote".freeze

        # What the form's lists are filled from: the server's repositories,
        # the machines it reaches over SSH and its projects. `error` says why
        # there are none (Orca isn't running here, say); the form then takes
        # what is typed.
        Catalog = Struct.new(:repos, :hosts, :projects, :error, keyword_init: true)

        class << self
          def label = "Orca"

          def config_help
            "repo is the Orca repo work happens in (\"name:app\", \"path:/code/app\" or \"id:…\", as `orca repo list` shows them). " \
              "For a remote host instead: host (\"ssh:<id>\", as `orca host list` shows them), project and provider. " \
              "environment is the paired server's name (`orca environment add`); leave it out for the Orca on this machine. " \
              "setup says whether the repo's own setup hooks run in a new worktree: \"skip\" (the default), \"run\" or \"inherit\"."
          end

          def config_example = { "repo" => "name:app" }

          def choices(name)
            [ Harbor::Runtimes::Choice.new(value: name, backend: name, label: "Orca",
                                           description: "Work runs on this server, in the Orca that runs beside the app."),
              Harbor::Runtimes::Choice.new(value: "#{name}#{REMOTE}", backend: name, label: "Orca (Remote)",
                                           description: "Orca still runs on this server, and does the work on another machine it reaches over SSH.") ]
          end

          def fields_partial = "harbor/runtimes/orca_fields"

          def remote_choice?(choice) = choice.value.end_with?(REMOTE)

          # Orca lists a server's SSH hosts only for the machine it is asked
          # on, never through a pairing code: a paired server has none here.
          def catalog(client: Harbor::Orca::Client.new)
            hosts = begin
              client.hosts.select(&:ssh?)
            rescue Harbor::Orca::Error
              []
            end
            Catalog.new(repos: client.repos, hosts:, projects: client.projects)
          rescue Harbor::Orca::Error => e
            Catalog.new(repos: [], hosts: [], projects: [], error: e.message)
          end

          def settings_from(fields, choice:, catalog: nil, runtime: nil, **)
            pairing = fields[:pairing_code_env].to_s.strip.presence
            if pairing && !pairing.match?(/\A[A-Z_][A-Z0-9_]*\z/)
              raise ArgumentError, "That field takes the name of an environment variable, like ORCA_PAIRING_CODE. To give the code itself, paste it into \"Pairing code\"."
            end
            code = fields[:pairing_code].to_s.strip
            raise ArgumentError, "A pairing code is one link with no spaces in it (orca://pair?…)." if code.match?(/\s/)
            forget = code.empty? && fields[:forget_pairing_code].to_s == "1"
            paired = code.present? || pairing.present? || (runtime&.secret? && !forget)

            config = { "setup" => fields[:setup].presence_in(SETUPS.keys), "environment" => fields[:environment].to_s.strip.presence,
                       "pairing_code_env" => pairing }
            if remote_choice?(choice)
              host = fields[:host].to_s.strip
              raise ArgumentError, "Choose the external host the work runs on." if host.blank?
              raise ArgumentError, "Choose who hosts the external host." unless PROVIDERS.key?(fields[:provider].to_s)
              raise ArgumentError, "Choose the project to work in." if fields[:project].blank?
              host = "ssh:#{host}" unless host.include?(":")
              name = paired ? nil : (catalog || self.catalog).hosts.find { |found| found.selector == host }&.name
              config.merge!("provider" => fields[:provider], "host" => host, "host_name" => name, "project" => fields[:project].to_s.strip)
            else
              # A server just paired from the page has its repositories listed
              # once the code is saved, so the runtime may be saved first and
              # the repository chosen next. It takes no work until then.
              raise ArgumentError, "Choose the repository to work in." if fields[:repo].blank? && !paired
              config["repo"] = fields[:repo].to_s.strip.presence
            end
            settings = { "config" => config.compact, "host" => nil }
            settings["secret"] = code if code.present?
            settings["secret"] = nil if forget
            settings
          end
          def keeps_workspaces? = true

          # An agent's tool rules are flags on the agent command, so they hold
          # here. An OpenAI model runs through codex, which can only enforce
          # some rules (Harbor::AgentSession::ToolPolicy): a choice whose
          # rules it can't keep is passed over.
          def enforces_tool_policy? = true

          def supports?(choice, allowed_tools: nil, disallowed_tools: nil)
            choice.model_provider&.key != "openai" ||
              Harbor::AgentSession::ToolPolicy.codex_supported?(allowed_tools:, disallowed_tools:)
          end

          def policy_hint(allowed_tools: nil, disallowed_tools: nil)
            return nil if Harbor::AgentSession::ToolPolicy.codex_supported?(allowed_tools:, disallowed_tools:)
            " The agent's tool rules need an Anthropic model: an OpenAI one can't enforce them."
          end
        end

        # Reached by a pairing code, pasted on the page or named in the
        # environment, and so possibly not the Orca on this machine.
        def paired? = runtime.secret? || pairing_code_env.present?

        # The lists the form offers, from the server this runtime reaches.
        def catalog = self.class.catalog(client: client)

        def remote? = host.present?
        def label = remote? ? "Orca (Remote)" : "Orca"
        def choice_value = remote? ? "#{runtime.backend}#{REMOTE}" : runtime.backend
        def provider_name = PROVIDERS[runtime.config["provider"].to_s]
        def host_name = runtime.config["host_name"].presence || host

        def place
          return [ provider_name, host_name ].compact_blank.join(" · ") if remote?
          return "Orca server paired here" if runtime.secret?
          return "Orca server (#{pairing_code_env})" if pairing_code_env
          environment || "This server"
        end

        def unready_reason
          return "the saved pairing code can't be read by this app (its secret key has changed); paste the code again" if runtime.secret_unreadable?
          return "the Orca server's pairing code isn't set (#{pairing_code_env})" if !runtime.secret? && pairing_code_env && pairing_code.blank?
          if remote?
            return "no project set" if project.blank?
          elsif repo.blank?
            return "no repository set"
          end
          "no runner address set (Settings)" unless Harbor::Runner.configured?
        end

        # A remote host posts its output to the runner address, so one that
        # only this machine can reach is no use to it.
        def warnings = remote? ? runner_address_warnings(host_name) : []

        # What to say when `who` (another machine) is to post to a runner
        # address that only this machine can reach.
        def runner_address_warnings(who)
          return [] unless Harbor::Runner.configured?
          address = URI.parse(Harbor::Runner.base_url).host.to_s rescue ""
          return [] unless address.in?(%w[localhost 127.0.0.1 ::1 [::1] 0.0.0.0])
          [ "The runner address (#{Harbor::Runner.base_url}) is this machine's own, which #{who} can't reach. Set one it can reach on the Settings page." ]
        end

        # Raises unless the server answers and can take work, and (for a
        # remote runtime) still knows the host.
        def health_check
          status = client.status
          raise "Orca #{status[:version]} is not ready" unless status[:ready]
          # Orca answers `host list` only for the machine it is asked on, never
          # through a pairing code, so a server reached by one can't be asked.
          if remote? && !paired? && client.hosts.none? { |found| found.selector == host }
            raise "Orca doesn't know the host #{host_name} any more"
          end
          status
        end

        def runner_name = [ runtime.name, environment ].compact_blank.uniq.join(" · ")

        # Where a new worktree is made: Orca::Client#create_worktree's
        # arguments.
        def worktree_place = remote? ? { project:, host: } : { repo: }

        def worktree_name(run) = "harbor-run-#{run.id}"

        # Makes a worktree for the run and starts `command` in a terminal
        # there. Returns at once with the Session; the command reports its own
        # output and result. `runner` is what the runner script is told
        # besides the command (Harbor::Runner.command_for: bundle:, attempt:).
        def start(run:, command:, base: nil, title: nil, **runner)
          worktree = create_worktree(run, base)
          begin
            terminal = client.start_terminal(worktree:, command: Harbor::Runner.command_for(run, command, **runner),
                                             title: title || "Run #{run.id}")
          rescue StandardError
            client.remove_worktree(worktree, force: true) rescue nil
            raise
          end
          Session.new(worktree_id: worktree.id, worktree_path: worktree.path, terminal: terminal.handle)
        end

        # Starts `command` in a new terminal of the worktree a session already
        # has, and returns the session for it. The worktree is left as it is.
        def restart(session, run:, command:, title: nil, **runner)
          terminal = client.start_terminal(worktree: "id:#{session.worktree_id}",
                                           command: Harbor::Runner.command_for(run, command, **runner),
                                           title: title || "Run #{run.id}")
          Session.new(worktree_id: session.worktree_id, worktree_path: session.worktree_path, terminal: terminal.handle)
        end

        # Closes every terminal of the session's worktree, which is the
        # run's alone: before a command is started there again, nothing of
        # an earlier one may be left running. False when there was nothing
        # to ask (the worktree is not known to the server any more).
        def clear(session)
          client.close_terminals(worktree: "id:#{session.worktree_id}")
        rescue Harbor::Orca::Error => e
          raise unless e.code == "selector_not_found"
          false
        end

        # Removes the worktree a run was given by name, when the run never
        # got to record it. False when there is none.
        def discard(run)
          client.remove_worktree("name:#{worktree_name(run)}", force: true, delete_branch: true)
        rescue Harbor::Orca::Error => e
          raise unless e.code == "selector_not_found"
          false
        end

        # Stops the run's command. False when it had already gone.
        def stop(session) = client.close_terminal(session.terminal)

        # Whether the session's terminal has nothing running in it any more:
        # its command ended, or the terminal itself is gone.
        def exited?(session)
          client.wait_for_exit(session.terminal, timeout: 1).exited?
        rescue Harbor::Orca::Error => e
          raise unless e.code == "terminal_handle_stale"
          true
        end

        # Removes the run's worktree, changes and all.
        def cleanup(session, delete_branch: true)
          client.remove_worktree("id:#{session.worktree_id}", force: true, delete_branch:)
        end

        # Makes the run's worktree. A server that has just been started knows
        # no repository, so one named by its folder ("path:/abs/repo") that
        # the server doesn't know is added to it, once, and asked for again.
        def create_worktree(run, base)
          place = worktree_place
          setup = runtime.config["setup"].presence || "skip"
          client.create_worktree(**place, name: worktree_name(run), base:, setup:)
        rescue Harbor::Orca::Error => e
          raise unless e.code == "repo_not_found" && place[:repo].to_s.start_with?("path:/")
          added = client.add_repo(path: place[:repo].delete_prefix("path:"))
          client.create_worktree(repo: added.selector, name: worktree_name(run), base:, setup:)
        end

        def client = options[:client] || (@client ||= Harbor::Orca::Client.new(environment:, pairing_code:))

        private

        def repo = runtime.config["repo"].to_s.strip.presence
        def host = runtime.config["host"].to_s.strip.presence
        def project = runtime.config["project"].to_s.strip.presence
        def environment = runtime.config["environment"].to_s.strip.presence
        def pairing_code_env = runtime.config["pairing_code_env"].to_s.strip.presence
        def pairing_code = runtime.secret.presence || (pairing_code_env && ENV[pairing_code_env].presence)
      end
    end
  end
end
