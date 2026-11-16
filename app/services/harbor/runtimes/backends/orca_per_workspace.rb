module Harbor
  module Runtimes
    module Backends
      # Work in an Orca of its own, on a machine made for the run and removed
      # after it: "Orca (per workspace)". The machine is made by an
      # environment recipe declared in the host's config file
      # (Harbor::EnvironmentRecipes), whose scripts Harbor runs itself to
      # Orca's contract (Harbor::Machines). Once the machine's Orca server
      # answers, the run is an Orca session like any other: a command in a
      # terminal of a worktree, wrapped so it reports back (Harbor::Runner).
      #
      # A runtime's config:
      #   "recipe"  the id of the recipe that makes the machine
      #   "setup"   whether the repository's own setup hooks run in the new
      #             worktree: "run", "skip" (default) or "inherit"
      #
      # Every Orca command for a run goes to that run's machine, with that
      # machine's pairing code (kept on its Harbor::Machine row and nowhere
      # else). `start` returns before the machine exists: `create` can take
      # many minutes, so it runs in a job, and the session is written on the
      # run when its terminal has started.
      #
      # Built to Orca 1.4.257's recipe contract and tested with stand-in
      # scripts and a stand-in for Orca. It has not yet made a real machine.
      class OrcaPerWorkspace < Orca
        # What a started run holds: its machine (the instance id) and, on
        # it, the worktree and terminal.
        Session = Struct.new(:machine, :worktree_id, :worktree_path, :terminal, keyword_init: true) do
          def to_h = { "machine" => machine, "worktree_id" => worktree_id, "worktree_path" => worktree_path, "terminal" => terminal }.compact
          def self.from(hash) = new(machine: hash["machine"], worktree_id: hash["worktree_id"], worktree_path: hash["worktree_path"], terminal: hash["terminal"])
        end

        # What `start` returns: nothing to write down yet. The session is
        # recorded by the job that makes the machine.
        Pending = Struct.new(:machine) do
          def to_h = {}
        end

        # How long an interrupted session waits for a machine that doesn't
        # answer before it is given a new one.
        UNREACHABLE = 10.minutes

        class << self
          def label = "Orca (per workspace)"

          def config_help
            "recipe is the id of an environment recipe declared in #{Harbor::ConfigFile.label} (environment_recipes): its create step starts a machine " \
              "for each run and its destroy step removes it. setup says whether the repository's own setup hooks run in a new worktree: " \
              "\"skip\" (the default), \"run\" or \"inherit\"."
          end

          def config_example = { "recipe" => "sandbox" }

          def choices(name)
            [ Harbor::Runtimes::Choice.new(value: name, backend: name, label: "Orca (per workspace)",
                                           description: "Each run gets a machine of its own, started by a recipe and removed when the run ends, with its own Orca on it.") ]
          end

          # Only a site that has declared a recipe can add one.
          def offered? = recipes.any?

          def unoffered_note
            problem = recipes_problem
            return "Orca (per workspace) can't be added: #{problem}" if problem
            "Orca (per workspace) starts a machine for each run and removes it afterwards. To add one, declare a recipe under " \
              "environment_recipes in #{Harbor::ConfigFile.label} (its create and destroy scripts), then come back."
          end

          def fields_partial = "harbor/runtimes/orca_per_workspace_fields"
          def page_partial = "harbor/runtimes/machines"

          # The declared recipes; none when the file can't be read (the
          # reason is `recipes_problem`).
          def recipes
            Harbor::EnvironmentRecipes.all
          rescue Harbor::EnvironmentRecipes::Error
            []
          end

          def recipes_problem = Harbor::EnvironmentRecipes.problems.first

          def settings_from(fields, choice:, **)
            id = fields[:recipe].to_s.strip
            raise ArgumentError, "Choose the recipe that makes the machine." if id.blank?
            raise ArgumentError, recipes_problem if recipes_problem
            raise ArgumentError, "#{id} is not a recipe declared in #{Harbor::ConfigFile.label}." unless recipes.any? { |recipe| recipe.id == id }
            { "config" => { "recipe" => id, "setup" => fields[:setup].presence_in(Orca::SETUPS.keys) }.compact, "host" => nil }
          end

          # The machine goes when the run does: there is nothing to go back to.
          def keeps_workspaces? = false
        end

        def label = "Orca (per workspace)"
        def choice_value = runtime.backend
        def remote? = false
        def place = recipe&.name || (recipe_id ? "#{recipe_id} (not declared)" : nil)
        def runner_name = runtime.name

        def recipe_id = runtime.config["recipe"].to_s.strip.presence

        # The runtime's recipe as declared now, or nil.
        def recipe = recipe_id && self.class.recipes.find { |found| found.id == recipe_id }

        def unready_reason
          return "no recipe chosen" if recipe_id.blank?
          problem = self.class.recipes_problem
          return problem if problem
          return "the recipe #{recipe_id} is not declared in #{Harbor::ConfigFile.label} any more" if recipe.nil?
          "no runner address set (Settings)" unless Harbor::Runner.configured?
        end

        # A machine posts its output to the runner address, so one that only
        # this machine can reach is no use to it.
        def warnings = runner_address_warnings("a machine made for a run")

        # The recipe is still declared and its scripts are there and can be
        # run. Nothing is started.
        def health_check
          problem = self.class.recipes_problem
          raise problem if problem
          found = recipe or raise "the recipe #{recipe_id.inspect} is not declared in #{Harbor::ConfigFile.label}"
          problems = found.script_problems
          raise "the recipe #{found.id} can't be run: #{problems.join('; ')}" if problems.any?
          true
        end

        # --- agent sessions (Harbor::AgentSession) ---

        def session_from(hash) = Session.from(hash)

        # Whether the run's machine is still being made (its own time limits
        # wait until it is).
        def setting_up?(run) = Harbor::Machines.setting_up?(run)

        # The run is over, however it ended: its machine goes.
        def run_over(run) = Harbor::Machines.release(run)

        # Asks for the run's machine and returns at once. The machine is made
        # and the command started by Harbor::Machines::ProvisionJob, which
        # writes the session on the run.
        def start(run:, command:, base: nil, title: nil, bundle: nil, attempt: 1, **)
          found = recipe or raise Harbor::AgentSession::Error, "#{runtime.name} has no usable recipe: #{unready_reason}"
          machine = Harbor::Machines.claim_for(run, runtime:, recipe: found, base:, workspace: worktree_name(run))
          run.with_lock do
            state = run.runner_state.to_h.deep_dup
            state.delete("session")
            state["machine"] = { "instance" => machine.instance_id, "phase" => "creating", "since" => Time.current.iso8601 }
            run.update_columns(runner_state: state)
          end
          Harbor::Machines::ProvisionJob.perform_later(run.id, attempt.to_i, { "command" => command, "base" => base, "title" => title,
                                                                              "bundle" => (Array(bundle).map(&:to_s) if bundle.present?) }.compact)
          Pending.new(machine.instance_id)
        end

        # Starts the run's command on its machine, which is up: the Orca
        # backend's own start, against the machine's server and the
        # repository at the recipe's projectRoot.
        def start_on(machine, **options)
          @machine = machine
          held = method(:start).super_method.call(**options.compact)
          Session.new(machine: machine.instance_id, worktree_id: held.worktree_id, worktree_path: held.worktree_path, terminal: held.terminal)
        end

        def restart(session, **options)
          held = on(session) { super }
          Session.new(machine: session.machine, worktree_id: held.worktree_id, worktree_path: held.worktree_path, terminal: held.terminal)
        end

        # False when there is no terminal, or the machine has gone already.
        def stop(session)
          return false if session.terminal.blank? || !machine_up?(session)
          on(session) { super }
        end

        def exited?(session)
          return true if session.terminal.blank? || !machine_up?(session)
          on(session) { super }
        end

        # Closes whatever is left in the run's worktree before it is started
        # there again. False when there is nothing to start again in: the
        # worktree or the machine is gone, or the machine has not answered
        # for a while; the run then gets a new machine.
        def clear(session)
          return false if session.worktree_id.blank? || !machine_up?(session)
          on(session) { super }
        rescue Harbor::Orca::Error => e
          raise unless e.code != "selector_not_found" && unreachable_for(session) > UNREACHABLE
          false
        end

        # Nothing to remove by name: a worktree goes with its machine.
        def discard(_run) = false

        # The worktree goes with the machine (run_over).
        def cleanup(_session, **) = true

        def worktree_place = { repo: "path:#{@machine&.project_root}" }

        def client
          options[:client] || (@client ||= begin
            code = @machine&.pairing_code or raise Harbor::Orca::Error.new("The run's machine is gone.", code: "machine_gone")
            Harbor::Orca::Client.new(pairing_code: code)
          end)
        end

        private

        def machine_of(session) = session.machine.present? ? Harbor::Machine.find_by(instance_id: session.machine) : nil

        def machine_up?(session) = machine_of(session)&.then { |machine| machine.created? && machine.pairing_code.present? } || false

        # Runs the block against the session's own machine, and keeps its
        # pairing code out of whatever goes wrong.
        def on(session)
          @machine = machine_of(session)
          @client = nil
          yield
        rescue Harbor::Orca::Error => e
          raise Harbor::Orca::Error.new(Harbor::Machines.redact(e.message, @machine&.pairing_code), code: e.code, data: nil)
        end

        # How long the session's run has been waiting to be started again.
        def unreachable_for(session)
          run = machine_of(session)&.run
          at = run && (Time.zone.parse(run.runner_state.to_h.dig("interrupted", "at").to_s) rescue nil)
          at ? Time.current - at : 0
        end
      end
    end
  end
end
