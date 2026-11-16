module Harbor
  module Machines
    # Makes a run's machine and starts the run's command on it: the work
    # behind a session on an "Orca (per workspace)" runtime, between the
    # moment the run is placed and the moment it is an ordinary Orca session.
    #
    #   1. Whatever an earlier try left (a machine that is up, or a `create`
    #      that never returned) is removed first, by the recipe's `destroy`.
    #      A run never has two machines; if that can't be confirmed, the run
    #      fails and the machine stays listed.
    #   2. `create` runs, its progress (stderr) going to the run's log. While
    #      it runs the machine's row is touched every few seconds; if the
    #      run ends meanwhile (stopped, say) `create` is stopped with
    #      everything it started, and `destroy` run.
    #   3. Its one JSON object is read. The machine's Orca server is asked,
    #      with the pairing code, for its status, told about the repository
    #      at `projectRoot`, and asked for a worktree and a terminal running
    #      the run's command (the Orca backend's own `start`).
    #   4. The session is written on the run, and the run's own clock starts.
    #
    # Nothing is held while `create` runs: no lock, no transaction and no
    # database connection.
    class Provisioner
      # The run fails with this message.
      Failed = Class.new(StandardError)

      # How often the machine's Orca is asked whether it is ready, and how
      # long between asks: a machine's address can take a moment to answer.
      READY_TRIES = 5
      class << self
        attr_writer :ready_wait
        def ready_wait = @ready_wait || 3
      end

      def initialize(run, attempt:, command:, base: nil, title: nil, bundle: nil)
        @run = run
        @attempt = attempt.to_i
        @command = command
        @base = base
        @title = title
        @bundle = bundle
      end

      def call
        @machine = Harbor::Machines.for_run(@run) or return
        return unless current?
        take or return
        result = make or return
        attach(result)
      rescue Failed => e
        fail!(e.message)
      rescue StandardError => e
        fail!("#{e.class.name.demodulize}: #{e.message}")
      end

      private

      def secret = @secret

      def redact(text) = Harbor::Machines.redact(text, secret)

      def note(text, tag: "machine") = Harbor::AgentSession.note(@run, "[#{tag}] #{redact(text)}")

      # Still the start this job was queued for: the run is going, and has
      # not been started again since.
      def current?
        @run.reload
        state = @run.runner_state.to_h
        @run.running? && state["attempt"].to_i == @attempt && state.dig("machine", "phase") == "creating"
      end

      # This call alone goes on: another that is still at it keeps the
      # machine.
      def take
        @machine.with_lock do
          next false unless @machine.live?
          next false if @machine.claim.present? && @machine.beat_at && @machine.beat_at > BEAT_STALE.ago
          @claim = SecureRandom.hex(8)
          # A `create` that was started and never said how it ended.
          @machine.status = "uncertain" if @machine.creating? && @machine.create_started_at.present?
          Harbor::Machines.stop_leftover(@machine) if @machine.uncertain?
          @machine.update!(claim: @claim, beat_at: Time.current, create_pid: nil, create_pid_mark: nil)
          true
        end
      end

      def mine? = Harbor::Machine.where(id: @machine.id, claim: @claim).exists?

      # The machine, made: what `create` printed. nil when the run ended
      # while it was being made.
      def make
        remove_leftover unless @machine.creating?
        recipe = @machine.declared_recipe or raise Failed, "The recipe #{@machine.recipe} is no longer declared in #{Harbor::ConfigFile.label}."
        timeout = Harbor::Machines.create_timeout(recipe)
        @machine.update!(create_started_at: Time.current, beat_at: Time.current, create_host: Socket.gethostname)
        note("starting a machine with the recipe #{recipe.name} (#{@machine.instance_id}); create may take up to #{ActiveSupport::Duration.build(timeout).inspect}")

        last = nil
        result = begin
          Harbor::Machines.without_connection do
            Script.run(recipe.create, chdir: Harbor::EnvironmentRecipes.root, env: Harbor::Machines.environment(@machine, "create"),
                       timeout:, tick: Harbor::Machines.beat, on_spawn: method(:spawned), on_tick: method(:beat),
                       on_stderr: ->(line) { last = redact(line); note(line, tag: "create") })
          end
        rescue Exception # rubocop:disable Lint/RescueException
          # The worker is going down: the step was stopped with it.
          uncertain rescue nil
          raise
        end

        if result.stopped
          return nil unless mine?
          uncertain
          note("the run ended while its machine was being made: create was stopped")
          Harbor::Machines.destroy!(@machine)
          return nil
        end
        if result.timed_out
          uncertain
          raise Failed, "The machine could not be made: create ran past its #{ActiveSupport::Duration.build(timeout).inspect} and was stopped, with everything it had started."
        end
        unless result.exit_status == 0
          uncertain
          raise Failed, [ "The machine could not be made: create exited #{result.exit_status.inspect}", last.presence&.truncate(300) ].compact.join(": ")
        end

        parsed = begin
          RecipeResult.parse(result.stdout, overflowed: result.overflowed)
        rescue RecipeResult::Invalid => e
          # What it printed is still `destroy`'s, when it was an object.
          uncertain(result: e.result)
          raise Failed, "The machine could not be used: #{e.message}."
        end
        @secret = parsed["pairingCode"]
        kept = @machine.with_lock do
          next false unless @machine.claim == @claim
          @machine.result = parsed
          @machine.update!(status: "created", claim: nil, ready_at: Time.current, create_pid: nil, create_pid_mark: nil)
          true
        end
        kept ? parsed : nil
      end

      # A run never has two machines: what an earlier try made, or may have
      # made, goes before `create` runs again.
      def remove_leftover
        note("removing what an earlier attempt left (#{@machine.instance_id}) before making the machine again")
        outcome = Harbor::Machines.destroy!(@machine)
        @machine.reload
        unless %i[destroyed skipped].include?(outcome)
          raise Failed, "An earlier attempt at this run may have left a machine (#{@machine.instance_id}) and it could not be removed" \
                        "#{": #{@machine.destroy_error}" if @machine.destroy_error.present?}. " \
                        "No second machine was made. It is listed on the runtime's page."
        end
        @machine.update!(status: "creating", claim: @claim, beat_at: Time.current, create_started_at: nil, released_at: nil, destroyed_at: nil,
                         destroy_error: nil, note: nil)
      end

      def spawned(pid)
        Harbor::Machine.where(id: @machine.id, claim: @claim)
                       .update_all(create_pid: pid, create_pid_mark: Harbor::Machines.process_mark(pid), beat_at: Time.current)
      end

      # Says the step is still running, and stops it when the run is over or
      # the machine is no longer this call's.
      def beat
        touched = Harbor::Machine.where(id: @machine.id, claim: @claim).update_all(beat_at: Time.current)
        touched.zero? || !current? ? :stop : nil
      rescue StandardError => e
        # The database could not be asked. That says nothing about the step.
        Rails.logger.error("[harbor] run #{@run.id}: the machine's heartbeat failed: #{e.class}: #{e.message}")
        nil
      end

      def uncertain(result: nil)
        @machine.result = result if result
        @machine.assign_attributes(status: "uncertain", claim: nil, create_pid: nil, create_pid_mark: nil)
        @machine.save!
      end

      # --- on the machine ---

      def attach(result)
        client = Harbor::Orca::Client.new(pairing_code: result["pairingCode"])
        await(client)
        runtime = Harbor.runtime_class.find_by(id: @run.runtime_id) or raise Failed, "The runtime it was placed on is gone."
        backend = runtime.adapter(client:)
        note("#{@machine.instance_id} is up; starting the run in #{result['projectRoot']}")
        session = backend.start_on(@machine, run: @run, command: @command, base: @base, title: @title, bundle: @bundle, attempt: @attempt)
        over = record(session)
        return unless over
        # Stopped in the meantime: the terminal has nothing to do, and the
        # machine goes.
        backend.stop(session) rescue nil
        Harbor::Machines.release(@run)
      rescue Harbor::Orca::Error => e
        raise Failed, redact(e.message)
      end

      def await(client)
        tries = 0
        begin
          tries += 1
          status = client.status
          raise Harbor::Orca::Error.new("the machine's Orca #{status[:version]} is not ready", code: "not_ready") unless status[:ready]
        rescue Harbor::Orca::Error
          raise if tries >= READY_TRIES
          sleep self.class.ready_wait
          retry
        end
      end

      # The run is a session now: its terminal is written down, and its own
      # time starts. True when the run ended first.
      def record(session)
        @run.with_lock do
          state = @run.runner_state.to_h.deep_dup
          next true if @run.finished? || state["attempt"].to_i != @attempt
          now = Time.current
          since = (Time.zone.parse(state.dig("machine", "since").to_s) rescue nil) || now
          # Time spent making the machine is not the session's.
          state["timeout_at"] = (Time.zone.parse(state["timeout_at"]) + (now - since)).iso8601 if state["timeout_at"].present?
          state.merge!("session" => session.to_h, "last_seen_at" => now.iso8601, "alive_at" => now.iso8601,
                       "machine" => { "instance" => @machine.instance_id, "phase" => "ready", "since" => now.iso8601 })
          @run.update_columns(runner_state: state)
          false
        end
      end

      # The run fails. The finisher gives back its slots and has the machine
      # removed; a run that was over already has its machine removed too.
      def fail!(message)
        message = redact(message)
        Rails.logger.error("[harbor] run #{@run.id}: its machine could not be made ready: #{message}")
        Harbor::AgentSession::Finisher.call(@run, error: "The agent session could not be started: #{message}")
        Harbor::Machines.release(@run) if @run.reload.finished?
      rescue StandardError => e
        Rails.logger.error("[harbor] run #{@run.id}: #{e.class}: #{Harbor::Machines.redact(e.message)}")
      end
    end
  end
end
