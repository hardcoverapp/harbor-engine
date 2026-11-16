require "open3"
require "socket"

module Harbor
  # A machine for each run: Harbor runs an environment recipe's scripts
  # (Harbor::EnvironmentRecipes) itself, to Orca's contract for per-workspace
  # environment recipes, because Orca's command line can't be asked to make
  # a worktree on a recipe.
  #
  #   create    started for a run placed on an "Orca (per workspace)" runtime
  #             (Provisioner, in ProvisionJob). It starts a machine, runs
  #             `orca serve` there and prints one JSON object on stdout:
  #             { "schemaVersion": 1, "pairingCode": "orca://pair?…",
  #               "projectRoot": "/abs/path", "userData": { … } }
  #   destroy   run when the run is over, however it ended (`release`, in
  #             DestroyJob), with the lifecycle JSON on stdin:
  #             { "schemaVersion": 1, "mode": "destroy", "recipeId": …,
  #               "instanceId": …, "workspaceName": …, "recipeResult": { … } }
  #             `recipeResult` is what `create` printed, and is left out when
  #             `create` never returned one: the script then finds the machine
  #             by its instance id.
  #
  # Both run with Harbor's own environment and Orca's variables added
  # (`environment`). Every machine is a row (Harbor::Machine) written before
  # `create` starts, and `sweep` removes whatever a finished run left behind.
  module Machines
    class Error < StandardError; end

    # How often a running `create` says it is still there, and how long
    # after its last word it is taken to have died with its process.
    BEAT = 5
    BEAT_STALE = 90.seconds
    # How long a `create` that has been asked for may wait for a worker.
    QUEUED = 10.minutes
    # How soon the sweep tries a machine again that it could not remove.
    RETRY_EVERY = 10.minutes
    # Anything that looks like a pairing code, in text about to be kept.
    PAIRING_CODE = %r{orca://[^\s"'\\]+}
    HIDDEN = "[pairing code]".freeze
    ERROR_CAP = 500

    # What a sweep did: machines it removed, ones it could not, ones still in
    # use by a run that is going, and ones left for a later pass.
    Report = Struct.new(:removed, :failed, :in_use, :waiting, :stopped, keyword_init: true) do
      def self.empty = new(removed: [], failed: [], in_use: [], waiting: [], stopped: [])

      def summary
        parts = [ ("#{removed.size} removed" if removed.any?), ("#{failed.size} could not be removed" if failed.any?),
                  ("#{waiting.size} left for the next pass" if waiting.any?), ("#{in_use.size} in use" if in_use.any?) ]
        parts.compact.to_sentence.presence || "no machines to remove"
      end
    end

    class << self
      # Seconds between a running step's heartbeats (tests shorten it).
      attr_writer :beat
      def beat = @beat || BEAT
    end

    module_function

    def for_run(run) = Harbor::Machine.find_by(run_id: run.id)

    # The run's machine row, made the first time: its instance id is the
    # run's own for as long as the run exists, however often `create` is run
    # for it.
    def claim_for(run, runtime:, recipe:, base: nil, workspace: nil)
      machine = Harbor::Machine.find_by(run_id: run.id)
      machine ||= begin
        Harbor::Machine.create!(run_id: run.id, runtime_id: runtime.id, recipe: recipe.id, status: "creating",
                                instance_id: "harbor-#{run.id}-#{SecureRandom.hex(4)}")
      rescue ActiveRecord::RecordNotUnique
        Harbor::Machine.find_by!(run_id: run.id)
      end
      machine.with_lock do
        # A machine that was done with (a person said it was gone) is asked
        # for again: a new round, under the same instance id.
        if machine.done?
          machine.assign_attributes(status: "creating", claim: nil, create_started_at: nil, beat_at: nil, create_pid: nil, create_pid_mark: nil,
                                    released_at: nil, destroyed_at: nil, destroying_at: nil, destroy_error: nil, note: nil)
        end
        machine.recipe_snapshot = snapshot(recipe).merge("base" => base.presence, "workspace" => workspace).compact
        machine.save!
      end
      machine
    end

    # What is kept of a recipe with its machine, so the machine can still be
    # removed if the recipe's declaration goes.
    def snapshot(recipe)
      { "name" => recipe.name, "destroy" => recipe.destroy, "destroy_disabled" => recipe.destroy_disabled? ? true : nil,
        "destroy_timeout" => recipe.timeout("destroy") }.compact
    end

    # The variables Orca gives a recipe's script, added to Harbor's own
    # environment (which the script inherits: that is where its secrets are).
    # The ones that name an Orca project or workspace are empty: there is none
    # yet. ORCA_REPO_PATH is the folder the recipe is declared in.
    def environment(machine, mode)
      workspace = machine.recipe_snapshot["workspace"].to_s
      { "ORCA_VM_MODE" => mode, "ORCA_VM_INSTANCE_ID" => machine.instance_id, "ORCA_RECIPE_ID" => machine.recipe,
        "ORCA_PROJECT_ID" => "", "ORCA_WORKSPACE_ID" => "", "ORCA_WORKSPACE_NAME" => workspace,
        "ORCA_REPO_PATH" => Harbor::EnvironmentRecipes.root, "ORCA_REPO_URL" => "", "ORCA_REPO_BRANCH" => workspace,
        "ORCA_REPO_REF" => machine.recipe_snapshot["base"].to_s, "ORCA_REPO_REF_HEAD" => "",
        "ORCA_RECIPE_RESULT_SCHEMA_VERSION" => "1", "ORCA_VERSION" => "" }
    end

    # The lifecycle JSON a step other than `create` reads on stdin, as Orca
    # writes it: one line.
    def payload(machine, mode)
      result = machine.result
      body = { "schemaVersion" => 1, "mode" => mode, "recipeId" => machine.recipe, "instanceId" => machine.instance_id,
               "workspaceName" => machine.recipe_snapshot["workspace"].presence, "recipeResult" => result }.compact
      "#{JSON.generate(body)}\n"
    end

    # `text` with every pairing code taken out: the ones given, and anything
    # shaped like one.
    def redact(text, *secrets)
      text = text.to_s.dup
      secrets.flatten.compact_blank.each { |secret| text.gsub!(secret.to_s, HIDDEN) }
      text.gsub(PAIRING_CODE, HIDDEN)
    end

    def create_timeout(recipe) = recipe.timeout("create") || Harbor::Setting.get(:machine_create_minutes).to_i.minutes.to_i

    # Whether the run's machine is still being made: `create` was asked for
    # and its worker has not gone quiet. A run in that state is not watched
    # for its own time limits (Harbor::AgentSession::Watch).
    def setting_up?(run)
      state = run.runner_state.to_h["machine"].to_h
      return false unless state["phase"] == "creating"
      machine = for_run(run) or return false
      return false unless machine.creating?
      return machine.beat_at > BEAT_STALE.ago if machine.beat_at
      since = (Time.zone.parse(state["since"].to_s) rescue nil) || machine.updated_at
      since > QUEUED.ago
    end

    # The run is over: its machine goes. Safe to call any number of times.
    def release(run)
      machine = for_run(run) or return nil
      return machine if machine.done?
      Harbor::Machine.where(id: machine.id, released_at: nil).update_all(released_at: Time.current)
      DestroyJob.perform_later(machine.id)
      machine
    rescue StandardError => e
      # Nothing is lost: the sweep finds a finished run's machine.
      Rails.logger.error("[harbor] run #{run.id}: could not queue its machine's removal: #{e.class}: #{redact(e.message)}")
      nil
    end

    # Removes a machine: runs its recipe's `destroy`. Returns :destroyed,
    # :skipped (the recipe removes nothing, or `create` never ran), :failed
    # (it is kept, to be tried again), :creating (its `create` is still
    # running: not yet) or :busy (another call is at it, or it is done with).
    def destroy!(machine)
      window = destroy_timeout(machine) + 60
      claimed = Harbor::Machine.where(id: machine.id, status: Harbor::Machine::LIVE)
                               .where("destroying_at IS NULL OR destroying_at < ?", window.seconds.ago)
                               .update_all(destroying_at: Time.current)
      return :busy if claimed.zero?

      waiting = machine.with_lock do
        if machine.creating? && machine.claim.present? && machine.beat_at && machine.beat_at > BEAT_STALE.ago
          machine.update_columns(destroying_at: nil)
          :creating
        elsif machine.creating? && machine.create_started_at.nil?
          finish(machine, "destroy_skipped", note: "create never ran, so there was nothing to remove.")
          :skipped
        end
      end
      return waiting if waiting

      abandon_create(machine) if machine.creating?
      recipe = machine.declared_recipe
      disabled = recipe ? recipe.destroy_disabled? : machine.recipe_snapshot["destroy_disabled"]
      command = recipe ? recipe.destroy : machine.recipe_snapshot["destroy"]
      if disabled
        finish(machine, "destroy_skipped", note: "The recipe has destroy: none, so nothing was run.")
        note(machine, "the recipe #{machine.recipe_name} has destroy: none, so nothing was run for #{machine.instance_id}")
        return :skipped
      end
      raise Error, "the recipe #{machine.recipe} is no longer declared in #{Harbor::ConfigFile.label}, and no destroy command was kept with the machine" if command.blank?

      secret = machine.pairing_code
      last = nil
      note(machine, "removing #{machine.instance_id} (#{machine.recipe_name})")
      result = without_connection do
        Script.run(command, chdir: Harbor::EnvironmentRecipes.root, env: environment(machine, "destroy"), stdin: payload(machine, "destroy"),
                   timeout: destroy_timeout(machine),
                   on_stderr: ->(line) { last = redact(line, secret); note(machine, last, tag: "destroy") })
      end
      unless result.ok?
        why = result.timed_out ? "ran past its #{destroy_timeout(machine)} seconds and was stopped" : "exited #{result.exit_status}"
        raise Error, [ "destroy #{why}", last.presence ].compact.join(": ")
      end
      finish(machine, "destroyed")
      note(machine, "#{machine.instance_id} removed")
      :destroyed
    rescue StandardError => e
      failed(machine, e)
      :failed
    end

    # Removes the machines finished runs left behind, and stops a run whose
    # machine has been up longer than the site allows. A machine that could
    # not be removed is tried again `RETRY_EVERY` (at once with `force`). A
    # host schedules this (SweepJob); the runtime's page has a button.
    def sweep(runtime: nil, force: false)
      report = Report.empty
      scope = Harbor::Machine.live
      scope = scope.where(runtime_id: runtime.id) if runtime
      limit = Harbor::Setting.get(:machine_max_hours).to_i
      scope.order(:id).each do |machine|
        run = machine.run
        if run && !run.finished? && limit.positive? && machine.created_at < limit.hours.ago && Harbor::AgentSession.session?(run)
          Harbor::AgentSession.stop!(run, reason: "timeout", note: "Stopped: its machine had been up for #{limit} hours, the longest a machine may live (Settings).")
          report.stopped << machine
          run.reload
        end
        next report.in_use << machine if run && !run.finished?
        next report.waiting << machine if !force && machine.destroy_tried_at && machine.destroy_tried_at > RETRY_EVERY.ago

        case destroy!(machine.reload)
        when :destroyed, :skipped then report.removed << machine
        when :failed then report.failed << machine.reload
        else report.waiting << machine
        end
      rescue StandardError => e
        Rails.logger.error("[harbor] sweeping machine #{machine.instance_id} failed: #{e.class}: #{redact(e.message)}")
        report.failed << machine
      end
      report.failed.each do |machine|
        Rails.logger.error("[harbor] machine #{machine.instance_id} (run #{machine.run_id}, recipe #{machine.recipe}) could not be removed " \
                           "after #{machine.destroy_attempts} tries: #{machine.destroy_error}")
      end
      report
    end

    # A person says the machine is gone (they removed it by hand, or it never
    # existed). Only for a machine whose run is over.
    def forget!(machine, by: nil)
      run = machine.run
      raise Error, "Run #{machine.run_id} is still going on #{machine.instance_id}: stop the run instead." if run && !run.finished?
      finish(machine, "forgotten", note: "Marked as gone#{" by #{by}" if by.present?} on #{Time.current.to_date.iso8601}.")
      machine
    end

    # A `create` whose worker has gone: whatever is left of its process on
    # this machine is stopped, and the machine is one that may or may not
    # exist.
    def abandon_create(machine)
      stop_leftover(machine)
      machine.update_columns(status: "uncertain", claim: nil, create_pid: nil, create_pid_mark: nil, updated_at: Time.current)
    end

    # What identifies a process besides its number, which is used again:
    # when it started, as `ps` says it. nil where `ps` can't say.
    def process_mark(pid)
      out, status = Open3.capture2e("ps", "-o", "lstart=", "-p", pid.to_s)
      status.success? ? out.strip.presence : nil
    rescue StandardError
      nil
    end

    # Runs the block with this thread holding no database connection, as a
    # step may take many minutes. Inside a transaction (a test's) the
    # connection stays.
    def without_connection
      pool = Harbor::Machine.connection_pool
      pool.release_connection if pool.active_connection? && !Harbor::Machine.connection.transaction_open?
      yield
    end

    # A line of Harbor's own about a machine, in its run's log.
    def note(machine, text, tag: "machine")
      run = machine.run or return
      Harbor::AgentSession.note(run, "[#{tag}] #{text}")
    rescue StandardError
      nil
    end

    def destroy_timeout(machine)
      (machine.declared_recipe&.timeout("destroy") || machine.recipe_snapshot["destroy_timeout"] ||
        Harbor::Setting.get(:machine_destroy_minutes).to_i.minutes).to_i
    end

    def finish(machine, status, note: nil)
      machine.update_columns(status:, sealed_result: nil, claim: nil, create_pid: nil, create_pid_mark: nil, destroying_at: nil,
                             destroy_error: nil, destroyed_at: Time.current, note:, updated_at: Time.current)
    end

    def failed(machine, error)
      message = redact(error.message, machine.pairing_code).truncate(ERROR_CAP)
      Harbor::Machine.where(id: machine.id).update_all([ "destroy_attempts = destroy_attempts + 1, destroy_tried_at = ?, destroy_error = ?, destroying_at = NULL, updated_at = ?",
                                                        Time.current, message, Time.current ])
      Rails.logger.error("[harbor] machine #{machine.instance_id} (run #{machine.run_id}) could not be removed: #{message}")
      note(machine, "#{machine.instance_id} could not be removed: #{message}. The sweep tries again, and it is listed on the runtime's page.")
    end

    def stop_leftover(machine)
      pid = machine.create_pid or return
      return unless machine.create_host == Socket.gethostname && machine.create_pid_mark.present? && process_mark(pid) == machine.create_pid_mark
      Process.kill("TERM", -pid) rescue nil
      deadline = Time.current + Script::GRACE
      sleep 0.05 while process_mark(pid) && Time.current < deadline
      Process.kill("KILL", -pid) rescue nil
    end
  end
end
