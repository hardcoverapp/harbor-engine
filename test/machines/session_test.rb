require "test_helper"

# An agent session on an "Orca (per workspace)" runtime: a machine is made
# for the run by a recipe's create step, the run becomes an ordinary Orca
# session on that machine's server, and the machine is removed by the
# recipe's destroy step however the run ends. The recipes are real small
# scripts and Orca is a stand-in: no machine, no Orca server and no agent is
# started.
class HarborMachinesSessionTest < ActionDispatch::IntegrationTest
  include HarborAgentSessions
  include HarborMachines
  include SingletonStub

  WatchJob = Harbor::AgentSession::WatchJob
  ProvisionJob = Harbor::Machines::ProvisionJob
  DestroyJob = Harbor::Machines::DestroyJob
  Watch = Harbor::AgentSession::Watch

  INIT = { "type" => "system", "subtype" => "init", "session_id" => "s-1", "model" => "claude-sonnet-5-5" }.freeze
  DONE = { "type" => "result", "subtype" => "success", "is_error" => false, "session_id" => "s-1", "result" => "All fixed.", "num_turns" => 2,
           "total_cost_usd" => 0.2, "duration_ms" => 9_000, "usage" => { "input_tokens" => 1, "output_tokens" => 2 } }.freeze

  setup { post "/login", params: { name: "Sam Settings" } }

  def phase(run) = run.reload.runner_state.dig("machine", "phase")

  # Everything kept or shown about a run and its machine, as text.
  def everything(run)
    get harbor.run_path(run)
    page = response.body
    get harbor.raw_run_path(run)
    raw = response.body
    get harbor.edit_runtime_path(@sandbox)
    runtime_page = response.body
    get harbor.runs_path
    [ page, raw, runtime_page, response.body, run.reload.attributes.to_json, run.run_events.to_json, live_log(run),
      Harbor::Machine.all.map { |machine| machine.attributes.to_json + machine.inspect }.join, enqueued_jobs.inspect ].join("\n")
  end

  # --- the whole session ---

  test "a run placed there is given a machine in a job, becomes an Orca session on it, and its machine is removed when it ends" do
    run = travel_to(Time.zone.parse("2026-11-15 10:00:00")) { start_machine_session(base: "main") }

    assert run.running?
    assert_equal [ "orca_per_workspace", "Sandbox", @sandbox.id ], [ run.executor, run.runner_name, run.runtime_id ]
    assert_nil run.reload.runner_state["session"], "no session until its command has started"
    assert_equal "creating", phase(run)
    assert_empty recipe_calls, "create does not run where the session was started (a request, perhaps)"
    assert_empty @orca.calls
    machine = machine_of(run)
    assert_equal [ "creating", "sandbox", @sandbox.id ], [ machine.status, machine.recipe, machine.runtime_id ]
    assert_match(/\Aharbor-#{run.id}-[0-9a-f]{8}\z/, machine.instance_id)
    assert_enqueued_with(job: ProvisionJob)
    travel_to(Time.zone.parse("2026-11-15 10:05:00")) { assert Harbor::AgentSession.setting_up?(run), "waiting for a worker is still setting up" }
    travel_to(Time.zone.parse("2026-11-15 10:15:00")) { assert_not Harbor::AgentSession.setting_up?(run), "but not for ever" }

    travel_to(Time.zone.parse("2026-11-15 10:20:00")) { provision! }

    # create ran from the host app's root with Orca's variables.
    assert_equal [ "create" ], recipe_calls
    assert_equal File.realpath(Rails.root.to_s), File.read(File.join(@recipe_dir, "create.pwd")).strip
    given = { "ORCA_VM_MODE" => "create", "ORCA_VM_INSTANCE_ID" => machine.instance_id, "ORCA_RECIPE_ID" => "sandbox",
              "ORCA_PROJECT_ID" => "", "ORCA_WORKSPACE_ID" => "", "ORCA_WORKSPACE_NAME" => "harbor-run-#{run.id}",
              "ORCA_REPO_PATH" => Rails.root.to_s, "ORCA_REPO_URL" => "", "ORCA_REPO_BRANCH" => "harbor-run-#{run.id}",
              "ORCA_REPO_REF" => "main", "ORCA_REPO_REF_HEAD" => "", "ORCA_RECIPE_RESULT_SCHEMA_VERSION" => "1", "ORCA_VERSION" => "" }
    # (The script also has whatever ORCA_ variables the app's own environment holds.)
    assert_equal given, recipe_env("create").slice(*given.keys)

    # The machine's Orca: asked for its status, told about the repository,
    # asked for a worktree and a terminal, each with the pairing code.
    code = pairing_code(run)
    assert_equal [ "status --json", "worktree create", "terminal create" ], @orca.commands
    @orca.calls.each { |argv| assert_equal code, argv[argv.index("--pairing-code") + 1], "every Orca command carries the machine's pairing code" }
    worktree = @orca.calls[1]
    assert_equal [ "path:/srv/app", "harbor-run-#{run.id}", "skip", "main" ],
                 %w[--repo --name --setup --base-branch].map { |flag| worktree[worktree.index(flag) + 1] }
    assert_match "HARBOR_RUNNER_URL=https://harbor.example.com/harbor/runner/runs/#{run.id}", @orca.terminal_commands.first
    assert_match "HARBOR_RUNNER_ATTEMPT=1", @orca.terminal_commands.first

    run.reload
    assert_equal({ "machine" => machine.instance_id, "worktree_id" => "repo-1::/work/harbor-run-#{run.id}",
                   "worktree_path" => "/work/harbor-run-#{run.id}", "terminal" => "term-1" }, run.runner_state["session"])
    assert_equal "ready", phase(run)
    assert_not Harbor::AgentSession.setting_up?(run)
    assert_equal Time.zone.parse("2026-11-15 10:50:00"), Time.zone.parse(run.runner_state["timeout_at"]), "the time create took is not the run's"
    assert_equal [ "created", code, "/srv/app" ], [ machine.reload.status, machine.pairing_code, machine.project_root ]
    assert_match "[machine] starting a machine with the recipe Test sandbox (#{machine.instance_id})", live_log(run)
    assert_match "[create] booting #{machine.instance_id}", live_log(run), "create's progress on stderr is in the run's log"

    # From here it is an Orca session like any other.
    post_output(run, ndjson(INIT, DONE))
    post_result(run, 0)
    run.reload
    assert_equal [ "ok", "s-1", "All fixed." ], [ run.status, run.session_id, run.output["text"] ]
    assert_equal "terminal close", @orca.commands.last
    assert_equal code, @orca.calls.last[@orca.calls.last.index("--pairing-code") + 1]
    assert_not_includes @orca.commands, "worktree rm", "the worktree goes with its machine"
    assert_enqueued_with(job: DestroyJob, args: [ machine.id ])
    assert_equal [ "create" ], recipe_calls, "destroy does not run in the runner's request"

    destroy!
    assert_equal %w[create destroy], recipe_calls
    assert_equal({ "schemaVersion" => 1, "mode" => "destroy", "recipeId" => "sandbox", "instanceId" => machine.instance_id,
                   "workspaceName" => "harbor-run-#{run.id}",
                   "recipeResult" => { "schemaVersion" => 1, "pairingCode" => code, "projectRoot" => "/srv/app",
                                       "userData" => { "provider" => "test", "resourceId" => "box-#{machine.instance_id}" } } }, destroy_payload)
    assert_equal [ "destroy", machine.instance_id, "sandbox" ], recipe_env("destroy").values_at("ORCA_VM_MODE", "ORCA_VM_INSTANCE_ID", "ORCA_RECIPE_ID")
    machine.reload
    assert_equal [ "destroyed", nil, nil ], [ machine.status, machine.sealed_result, machine.pairing_code ], "the pairing code goes with the machine"
    assert_match "[machine] #{machine.instance_id} removed", live_log(run)
  end

  test "the pairing code is in no log, page, error, event, job or stored field but the machine's own, encrypted" do
    logged = StringIO.new
    extra = ActiveSupport::Logger.new(logged)
    Rails.logger.broadcast_to(extra)
    declare_recipes("sandbox" => recipe(destroy: "destroy-fail"))
    run = running_machine_session
    code = pairing_code(run)
    machine = machine_of(run)
    assert_no_match "SECRET", machine.sealed_result
    assert_no_match "SECRET", everything(run), "while it runs"
    assert_match "[create] orca serve said: [pairing code]", live_log(run), "a script that prints the code has it taken out of the log"

    # Orca refusing with the code in its message, and a destroy that echoes
    # its stdin, are the two ways it could reach an error.
    with_stub(@orca, :call, ->(_argv, timeout:) { [ JSON.generate("ok" => false, "error" => { "code" => "nope", "message" => "bad code #{code}" }), "", 1 ] }) do
      error = assert_raises(Harbor::Orca::Error) { @sandbox.adapter.exited?(Harbor::AgentSession.session_of(run)) }
      assert_equal "orca terminal wait: bad code [pairing code]", error.message
    end
    post_output(run, ndjson(INIT, DONE))
    post_result(run, 0)
    destroy!
    machine.reload
    assert_equal [ "created", 1 ], [ machine.status, machine.destroy_attempts ]
    assert_match "destroy exited 1: the provider refused; payload was", machine.destroy_error
    assert_match "[pairing code]", machine.destroy_error
    assert_equal code, machine.pairing_code, "kept while the machine may still be up: the next try needs it"

    assert_no_match "SECRET", everything(run), "after it ended and its destroy failed"
    assert_no_match "SECRET", logged.string, "the app's own log"
  ensure
    Rails.logger.stop_broadcasting_to(extra)
  end

  test "the runtime's setup hooks setting is passed to the worktree, and a server that doesn't know the repository is told about it" do
    @sandbox.update!(config: { "recipe" => "sandbox", "setup" => "run" })
    @orca.refuse("worktree create", code: "repo_not_found")
    run = running_machine_session
    assert_equal [ "status --json", "worktree create", "repo add", "worktree create", "terminal create" ], @orca.commands
    assert_equal "/srv/app", @orca.calls[2][@orca.calls[2].index("--path") + 1]
    assert_equal "run", @orca.calls[3][@orca.calls[3].index("--setup") + 1]
    assert_equal "ready", phase(run)
  end

  # --- create that does not give a machine ---

  test "a create that fails ends the run, and destroy is run with the instance id and no result" do
    declare_recipes("sandbox" => recipe(create: "create-fail"))
    run = start_machine_session
    provision!
    run.reload
    assert_equal "error", run.status
    assert_equal "The agent session could not be started: The machine could not be made: create exited 3: no capacity in the region", run.error
    assert_empty @orca.calls
    machine = machine_of(run)
    assert_equal "uncertain", machine.status

    destroy!
    assert_equal %w[create destroy], recipe_calls
    assert_equal({ "schemaVersion" => 1, "mode" => "destroy", "recipeId" => "sandbox", "instanceId" => machine.instance_id,
                   "workspaceName" => "harbor-run-#{run.id}" }, destroy_payload, "no recipeResult: the script finds the machine by its instance id")
    assert_equal "destroyed", machine.reload.status
    assert_equal 0, @sandbox.busy, "its slot is given back"
  end

  test "a create that runs past its timeout is stopped with its whole process tree, and destroy is run" do
    declare_recipes("sandbox" => recipe(create: "create-hang", timeout_seconds: { "create" => 1 }))
    run = start_machine_session
    provision!
    assert_equal [ "error", "The agent session could not be started: The machine could not be made: create ran past its 1 second and was stopped, with everything it had started." ],
                 [ run.reload.status, run.error ]
    sleep 0.2
    assert_not process_alive?(File.read(File.join(@recipe_dir, "child.pid")).to_i), "what create started is stopped with it"
    destroy!
    assert_equal %w[create destroy], recipe_calls
    assert_not destroy_payload.key?("recipeResult")
    assert_equal "destroyed", machine_of(run).status
  end

  test "a step with no timeout of its own gets the setting's" do
    Harbor::Setting.set!(:machine_create_minutes, 7)
    Harbor::Setting.set!(:machine_destroy_minutes, 3)
    found = Harbor::EnvironmentRecipes.find("sandbox")
    assert_equal 420, Harbor::Machines.create_timeout(found)
    run = start_machine_session
    assert_equal 180, Harbor::Machines.destroy_timeout(machine_of(run))
    declare_recipes("sandbox" => recipe(timeout_seconds: 45))
    assert_equal [ 45, 45 ], [ Harbor::Machines.create_timeout(Harbor::EnvironmentRecipes.find("sandbox")), Harbor::Machines.destroy_timeout(machine_of(run)) ]
  end

  test "noise on stdout is refused without repeating it, and destroy is run" do
    declare_recipes("sandbox" => recipe(create: "create-noise"))
    run = start_machine_session
    provision!
    assert_equal "error", run.reload.status
    assert_match "create printed something other than one JSON object on stdout (2 lines): progress and errors go to stderr", run.error
    assert_no_match "SECRET", run.error + live_log(run)
    destroy!
    assert_equal %w[create destroy], recipe_calls
    assert_not destroy_payload.key?("recipeResult")
  end

  test "a recipe that returns an SSH connection is refused, saying so, and destroy is given what it returned" do
    declare_recipes("sandbox" => recipe(create: "create-ssh"))
    run = start_machine_session
    provision!
    assert_equal "error", run.reload.status
    assert_match "the recipe returned an SSH connection, which isn't supported yet: Harbor only runs recipes that start an Orca server", run.error
    assert_empty @orca.calls
    destroy!
    assert_equal "ssh", destroy_payload.dig("recipeResult", "connection", "type")
    assert_equal "box-#{machine_of(run).instance_id}", destroy_payload.dig("recipeResult", "userData", "resourceId")
    assert_equal "destroyed", machine_of(run).status
  end

  test "results that are not Orca-server mode's are each refused with what is wrong" do
    parse = ->(hash) { Harbor::Machines::RecipeResult.parse(JSON.generate(hash)) }
    good = { "pairingCode" => "orca://pair?x", "projectRoot" => "/srv/app" }
    assert_equal good, parse.(good), "schemaVersion and userData are optional"
    { good.except("pairingCode") => /no pairingCode/, good.merge("projectRoot" => "app") => /projectRoot must be an absolute path/,
      good.except("projectRoot") => /no projectRoot/, good.merge("schemaVersion" => 2) => /schemaVersion 2; only 1 is supported/,
      good.merge("userData" => "x") => /userData must be an object/ }.each do |result, message|
      error = assert_raises(Harbor::Machines::RecipeResult::Invalid) { parse.(result) }
      assert_match message, error.message
      assert_no_match "orca://", error.message
    end
    assert_raises(Harbor::Machines::RecipeResult::Invalid) { Harbor::Machines::RecipeResult.parse("") }
    assert_raises(Harbor::Machines::RecipeResult::Invalid) { Harbor::Machines::RecipeResult.parse("[1]") }
  end

  test "a machine whose Orca can't start the run ends the run, and the machine is removed with its result" do
    @orca.refuse("terminal create")
    run = start_machine_session
    provision!
    assert_equal [ "error", "The agent session could not be started: orca terminal create: refused: runtime_unavailable" ], [ run.reload.status, run.error ]
    destroy!
    assert_equal %w[create destroy], recipe_calls
    assert_equal "box-#{machine_of(run).instance_id}", destroy_payload.dig("recipeResult", "userData", "resourceId")
    assert_equal "destroyed", machine_of(run).status
  end

  test "a machine whose Orca is not ready is asked again before the run is given up" do
    answers = 0
    original = @orca.method(:call)
    with_stub(@orca, :call, lambda { |argv, timeout:|
      next original.call(argv, timeout:) unless argv[1] == "status" && (answers += 1) < 3
      [ "", "connection refused", 1 ]
    }) do
      run = running_machine_session
      assert_equal 3, answers
      assert_equal "ready", phase(run)
    end
  end

  test "create holds no transaction of its own and no lock while it runs" do
    depth = nil
    original = Harbor::Machines::Script.method(:run)
    run = start_machine_session
    with_stub(Harbor::Machines::Script, :run, lambda { |command, **options|
      depth = Harbor::Machine.connection.open_transactions
      original.call(command, **options)
    }) { provision! }
    assert_equal 1, depth, "only the test's own transaction is open"
    assert_equal "ready", phase(run)
  end

  # --- stops and timeouts ---

  test "stopping a run while its machine is being made stops create and removes whatever it made" do
    declare_recipes("sandbox" => recipe(create: "create-hang"))
    run = start_machine_session
    stopper = Thread.new do
      sleep 0.1 until File.exist?(File.join(@recipe_dir, "child.pid"))
      Harbor::AgentSession.stop!(Harbor::Run.find(run.id))
    end
    provision!
    stopper.join
    assert_equal "canceled", run.reload.status
    sleep 0.2
    assert_not process_alive?(File.read(File.join(@recipe_dir, "child.pid")).to_i)
    assert_equal %w[create destroy], recipe_calls, "the job that ran create runs destroy itself"
    assert_not destroy_payload.key?("recipeResult")
    assert_equal "destroyed", machine_of(run).status
    assert_match "[machine] the run ended while its machine was being made: create was stopped", live_log(run)
    destroy!
    assert_equal %w[create destroy], recipe_calls, "and it is not removed twice"
  end

  test "a run stopped before its create started never runs create" do
    run = start_machine_session
    Harbor::AgentSession.stop!(run)
    assert_equal "canceled", run.reload.status
    perform_enqueued_jobs(only: [ ProvisionJob, DestroyJob ])
    assert_empty recipe_calls, "nothing was made, so nothing is run"
    assert_equal [ "destroy_skipped", "create never ran, so there was nothing to remove." ], machine_of(run).attributes.values_at("status", "note")
  end

  test "a stopped session's terminal is closed on its machine, and the machine is removed" do
    run = running_machine_session
    Harbor::AgentSession.stop!(run)
    assert_equal "canceled", run.reload.status
    assert_equal "terminal close", @orca.commands.last
    destroy!
    assert_equal %w[create destroy], recipe_calls
    assert_equal "destroyed", machine_of(run).status
  end

  test "a session that runs out of time is stopped and its machine removed; while the machine is being made no limit applies" do
    run = travel_to(Time.zone.parse("2026-11-15 10:00:00")) { start_machine_session(timeout: 600, idle_timeout: 60) }
    travel_to(Time.zone.parse("2026-11-15 10:25:00")) do
      machine_of(run).update!(claim: "at-work", create_started_at: 20.minutes.ago, beat_at: 5.seconds.ago)
      assert_equal [ 60, 60, 60 ], %w[timeout idle silent].map { |check| Watch.call(run.reload, check) }, "each check waits while create is running"
      assert run.reload.running?
      machine_of(run).update!(claim: nil, create_started_at: nil, beat_at: nil)
      provision!
    end
    assert_equal Time.zone.parse("2026-11-15 10:35:00"), Time.zone.parse(run.reload.runner_state["timeout_at"])

    travel_to(Time.zone.parse("2026-11-15 10:36:00")) { Watch.call(run, "timeout") }
    assert_equal [ "timeout", "Stopped: it had 10 minutes and was still running." ], [ run.reload.status, run.error ]
    destroy!
    assert_equal %w[create destroy], recipe_calls
    assert_equal "destroyed", machine_of(run).status
  end

  test "a kept worktree is not a kept machine" do
    run = running_machine_session(keep_worktree: true)
    post_result(run, 0)
    destroy!
    assert_equal "destroyed", machine_of(run).status
    assert_not Harbor::Runtimes::Backends::OrcaPerWorkspace.keeps_workspaces?
  end

  test "a recipe with destroy: none runs nothing and says so" do
    declare_recipes("sandbox" => recipe(destroy: "none"))
    run = running_machine_session
    post_result(run, 0)
    destroy!
    assert_equal [ "create" ], recipe_calls
    machine = machine_of(run)
    assert_equal [ "destroy_skipped", "The recipe has destroy: none, so nothing was run.", nil ], [ machine.status, machine.note, machine.sealed_result ]
  end

  # --- restarts ---

  test "after the app restarts mid-run the session carries on, and one whose terminal is gone is started again on the same machine" do
    run = running_machine_session
    code = pairing_code(run)
    clear_enqueued_jobs

    Harbor::AgentSession.recover!
    assert_enqueued_with(job: WatchJob, args: [ run.id, "silent", 1 ])
    assert run.reload.running?
    assert_equal [ "create" ], recipe_calls, "nothing is made again"

    # Its terminal went with the machine's Orca restarting.
    @orca.exited = true
    travel(20.minutes) { Watch.call(run.reload, "silent") }
    assert run.reload.runner_state["interrupted"].present?
    Harbor::AgentSession::Interruption.resume(run)
    run.reload
    assert_nil run.runner_state["interrupted"]
    assert_equal [ machine_of(run).instance_id, "term-2" ], run.runner_state["session"].values_at("machine", "terminal")
    assert_equal [ "terminal wait", "terminal close", "terminal create" ], @orca.commands.last(3)
    @orca.calls.last(3).each { |argv| assert_equal code, argv[argv.index("--pairing-code") + 1] }
    assert_equal [ "create" ], recipe_calls, "the machine it has is the one it carries on in"
    assert_no_enqueued_jobs only: ProvisionJob
  end

  test "an app that went down during create: the half-made machine is destroyed by its instance id, and create runs again under the same id" do
    run = travel_to(Time.zone.parse("2026-11-15 10:00:00")) { start_machine_session }
    machine = machine_of(run)
    clear_enqueued_jobs
    # A create that was running when the app died: a process of its own,
    # still there, and a heartbeat that stopped.
    leftover = Process.spawn("sleep 300", pgroup: true)
    Process.detach(leftover)
    machine.update!(claim: "dead-worker", create_started_at: Time.zone.parse("2026-11-15 10:00:05"), beat_at: Time.zone.parse("2026-11-15 10:01:00"),
                    create_pid: leftover, create_pid_mark: Harbor::Machines.process_mark(leftover), create_host: Socket.gethostname)

    travel_to(Time.zone.parse("2026-11-15 10:01:30")) do
      assert Harbor::AgentSession.setting_up?(run), "a heartbeat a moment old is a create still running"
    end
    travel_to(Time.zone.parse("2026-11-15 10:30:00")) do
      assert_not Harbor::AgentSession.setting_up?(run)
      Harbor::AgentSession.recover!
      Watch.call(run.reload, "silent")
      assert_equal "it was cut off while being started", run.reload.runner_state.dig("interrupted", "reason")
      assert run.running?, "the run is not over"
      Harbor::AgentSession::Interruption.resume(run)
      assert_enqueued_with(job: ProvisionJob)
      assert_equal 3, run.reload.runner_state["attempt"], "being cut off and being started again are each a new attempt"
      provision!
    end

    sleep 0.2
    assert_not process_alive?(leftover), "what was left of the old create is stopped first"
    assert_equal %w[destroy create], recipe_calls
    assert_equal [ machine.instance_id, false ], [ destroy_payload["instanceId"], destroy_payload.key?("recipeResult") ]
    assert_equal machine.instance_id, recipe_env("create")["ORCA_VM_INSTANCE_ID"], "the instance id is the run's, however often create runs"
    run.reload
    assert_equal [ "ready", "term-1" ], [ phase(run), run.runner_state.dig("session", "terminal") ]
    assert_match "HARBOR_RUNNER_ATTEMPT=3", @orca.terminal_commands.last
    assert_equal "created", machine.reload.status
    assert_match "[machine] removing what an earlier attempt left (#{machine.instance_id}) before making the machine again", live_log(run)
  ensure
    (Process.kill("KILL", -leftover) rescue nil) if leftover
  end

  test "when what an interrupted create left can't be removed, no second machine is made: the run fails and the machine stays listed" do
    declare_recipes("sandbox" => recipe(destroy: "destroy-fail"))
    run = start_machine_session
    machine_of(run).update!(claim: "dead-worker", create_started_at: 30.minutes.ago, beat_at: 29.minutes.ago)
    provision!
    assert_equal %w[destroy], recipe_calls, "create is not run again"
    assert_equal "error", run.reload.status
    assert_match(/An earlier attempt at this run may have left a machine \(harbor-#{run.id}-\h+\) and it could not be removed: destroy exited 1.*No second machine was made/, run.error)
    machine = machine_of(run)
    assert_equal [ "uncertain", 1 ], [ machine.status, machine.destroy_attempts ]
  end

  test "a job left over from an earlier start, or one run twice, does nothing" do
    run = start_machine_session
    job = enqueued_jobs.find { |queued| queued["job_class"] == "Harbor::Machines::ProvisionJob" }
    arguments = ActiveJob::Arguments.deserialize(job["arguments"])
    provision!
    ProvisionJob.perform_now(*arguments)
    assert_equal [ "create" ], recipe_calls, "the machine is up: the same job again makes nothing"
    assert_equal "term-1", run.reload.runner_state.dig("session", "terminal")

    run.update_columns(runner_state: run.runner_state.merge("attempt" => 2))
    ProvisionJob.perform_now(*arguments)
    assert_equal [ "create" ], recipe_calls
  end

  test "an interrupted session whose machine has stopped answering is given a new machine, after the old one is destroyed" do
    run = running_machine_session
    first = machine_of(run).instance_id
    @orca.exited = true
    travel(20.minutes) { Watch.call(run.reload, "silent") }
    cut = run.reload.runner_state["interrupted"]
    assert cut.present?

    down = ->(_argv, timeout:) { [ "", "connection refused", 1 ] }
    with_stub(@orca, :call, down) do
      assert_equal 60, Harbor::AgentSession::Interruption.resume(run), "a machine that doesn't answer is asked again for a while"
      assert run.reload.running?
      run.update_columns(runner_state: run.runner_state.deep_merge("interrupted" => { "at" => 11.minutes.ago.iso8601 }))
      assert_nil Harbor::AgentSession::Interruption.resume(run)
    end
    assert_enqueued_with(job: ProvisionJob)
    provision!
    assert_equal %w[create destroy create], recipe_calls
    assert_equal first, destroy_payload["instanceId"]
    assert destroy_payload.key?("recipeResult"), "the machine that was up is removed with its result"
    assert_equal [ first, "created" ], machine_of(run).attributes.values_at("instance_id", "status")
    assert_equal "ready", phase(run)
  end

  # --- the sweep ---

  test "the sweep removes what finished runs left, tries failures again, lists what it could not remove and leaves machines in use" do
    declare_recipes("sandbox" => recipe(destroy: "destroy-fail"))
    left = running_machine_session
    post_result(left, 0)
    destroy!
    in_use = running_machine_session
    gone = running_machine_session
    Harbor::Run.where(id: gone.id).delete_all
    clear_enqueued_jobs
    assert_equal 1, machine_of(left).destroy_attempts

    report = Harbor::Machines.sweep
    assert_equal [ [ machine_of(gone) ], [ machine_of(left) ], [ machine_of(in_use) ] ], [ report.failed, report.waiting, report.in_use ],
                 "a machine just tried is left for a later pass; one whose run is gone is tried"
    assert_equal "1 could not be removed, 1 left for the next pass, and 1 in use", report.summary

    report = Harbor::Machines.sweep(force: true)
    assert_equal [ machine_of(left), machine_of(gone) ], report.failed
    assert_equal [ 2, 2 ], report.failed.map(&:destroy_attempts)
    assert_match(/destroy exited 1/, report.failed.first.destroy_error)
    assert machine_of(left).pairing_code.present?, "what destroy needs is kept until it works"

    # The script is fixed: the next pass removes them, with the result.
    declare_recipes("sandbox" => recipe)
    travel(11.minutes) do
      report = Harbor::Machines::SweepJob.perform_now
      assert_equal [ [ machine_of(left), machine_of(gone) ], [], [ machine_of(in_use) ] ], [ report.removed, report.failed, report.in_use ]
    end
    assert_equal %w[destroyed destroyed created], [ left, gone, in_use ].map { |run| machine_of(run).status }
    assert destroy_payload.key?("recipeResult")
    assert_nil machine_of(left).sealed_result
    assert in_use.reload.running?
  end

  test "a machine is still removed after its recipe's declaration is gone, by the destroy command kept with it" do
    run = running_machine_session
    post_result(run, 0)
    declare_recipes("other" => recipe)
    destroy!
    assert_equal %w[create destroy], recipe_calls
    assert_equal "destroyed", machine_of(run).status
  end

  test "the sweep stops a run whose machine has lived longer than the site allows" do
    Harbor::Setting.set!(:machine_max_hours, 2)
    run = running_machine_session(timeout: nil)
    report = travel(3.hours) { Harbor::Machines.sweep }
    assert_equal [ "timeout", "Stopped: its machine had been up for 2 hours, the longest a machine may live (Settings)." ], [ run.reload.status, run.error ]
    assert_equal [ machine_of(run) ], report.stopped
    assert_equal "destroyed", machine_of(run).status
  end

  test "two removals at once run destroy once, and a machine whose create is still running is not removed yet" do
    run = running_machine_session
    post_result(run, 0)
    machine = machine_of(run)
    machine.update_columns(destroying_at: Time.current)
    assert_equal :busy, Harbor::Machines.destroy!(machine)
    assert_equal [ "create" ], recipe_calls
    machine.update_columns(destroying_at: nil)
    assert_equal :destroyed, Harbor::Machines.destroy!(machine)
    assert_equal :busy, Harbor::Machines.destroy!(machine), "done with"

    other = start_machine_session
    machine_of(other).update!(claim: "at-work", create_started_at: 1.minute.ago, beat_at: 2.seconds.ago)
    other.finish!(status: "canceled")
    assert_equal :creating, Harbor::Machines.destroy!(machine_of(other))
    assert_enqueued_with(job: DestroyJob) { DestroyJob.perform_now(machine_of(other).id) }
    assert_equal "creating", machine_of(other).status
  end

  test "a person can say a leftover machine is gone, but not one a run is still using" do
    run = running_machine_session
    error = assert_raises(Harbor::Machines::Error) { Harbor::Machines.forget!(machine_of(run), by: "Sam") }
    assert_match "Run #{run.id} is still going", error.message
    post_result(run, 0)
    Harbor::Machines.forget!(machine_of(run), by: "Sam")
    machine = machine_of(run)
    assert_equal [ "forgotten", nil ], [ machine.status, machine.sealed_result ]
    assert_match(/\AMarked as gone by Sam on \d{4}-\d\d-\d\d\.\z/, machine.note)
    assert_empty Harbor::Machines.sweep.failed
  end
end
