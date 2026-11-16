ENV["RAILS_ENV"] = "test"

require_relative "dummy/config/environment"
require "rails/test_help"
require "redis-client"
require "tmpdir"
require "open3"

# Capacity slots are kept in Redis. A host gives Harbor its own connection;
# the tests use REDIS_URL, in a namespace of their own.
HARBOR_TEST_REDIS = RedisClient.config(url: ENV.fetch("REDIS_URL", "redis://127.0.0.1:6379/0")).new_pool(size: 2)
Harbor.config.redis = ->(&block) { HARBOR_TEST_REDIS.with(&block) }
Harbor.config.slot_key = ->(line) { "harbor:test:slots:#{line}" }

module HarborTestConfig
  # Harbor.config is process-wide; put back what a test changed.
  def self.included(base)
    base.setup do
      @harbor_export = Harbor.config.export
      @harbor_fallbacks = Harbor.config.env_fallbacks.dup
      Harbor.config.export = nil
      Harbor.config.env_fallbacks.clear
      Harbor::Setting.delete_all
    end
    base.teardown do
      Harbor.config.export = @harbor_export
      Harbor.config.env_fallbacks.replace(@harbor_fallbacks)
    end
  end
end

# Swap a singleton method for the block's duration and put the original back.
module SingletonStub
  def with_stub(object, name, value = nil, &block_body)
    original = object.method(name)
    impl = value.respond_to?(:call) ? value : ->(*, **) { value }
    object.define_singleton_method(name) { |*args, **kw, &blk| impl.call(*args, **kw, &blk) }
    block_body.call
  ensure
    object.singleton_class.send(:remove_method, name) rescue nil
    object.define_singleton_method(name, original) if original && !object.respond_to?(name)
  end
end

# A host with databases, for the Databases tests: a config file of its own
# (written to a temp folder and rewritten as a test declares more), the ENV
# keys it names, a backup folder and the masking rules in test/fixtures.
# Everything is put back afterwards, ENV included.
module HarborDatabasesConfig
  CONFIG = %i[config_file backup_root backup_host_root masking_rules_path greenmask_bin greenmask_pg_bin_path backup_bucket_env_prefix
              staging_lock_role restore_application_name restore_spared_applications backup_kind_notes
              database_operation database_schedule].freeze
  RULES = File.expand_path("fixtures/masking", __dir__)
  STAGING_SWITCH = "TEST_STAGING_RESTORES_ENABLED".freeze

  def self.included(base)
    base.include HarborTestConfig
    base.include SingletonStub
    base.setup do
      @harbor_env = ENV.to_h
      @harbor_database_config = CONFIG.index_with { |name| Harbor.config.public_send(name) }
      @config_dir = Dir.mktmpdir("harbor-config")
      Harbor.config.config_file = File.join(@config_dir, "harbor.yml")
      @harbor_file = { "databases" => {}, "restore_environments" => {} }
      Harbor::Databases.reset!
      @backup_root = Dir.mktmpdir("harbor-backups")
      Harbor.config.backup_root = @backup_root
      Harbor.config.masking_rules_path = RULES
      Harbor.config.backup_bucket_env_prefix = "TEST_BACKUP_S3"
      ENV.delete(STAGING_SWITCH)
      # The app's own database as a deployed host names it. The suite's own
      # DATABASE_URL names a server with no database, which isn't a target.
      ENV["DATABASE_URL"] = "postgres://app:app-secret@app-db.internal:5432/app_production"
      ENV.keys.grep(/\ATEST_BACKUP_S3_/).each { |key| ENV.delete(key) }
    end
    base.teardown do
      ENV.replace(@harbor_env)
      @harbor_database_config.each { |name, value| Harbor.config.public_send("#{name}=", value) }
      Harbor::Databases.reset!
      [ @backup_root, @config_dir ].each { |dir| FileUtils.remove_entry(dir) if dir && File.exist?(dir) }
    end
  end

  # Write the host's config file: YAML text (ERB and all), or a hash.
  def write_harbor_file(content)
    File.write(Harbor.config.config_file, content.is_a?(String) ? content : content.to_yaml)
  end

  # "shop" has cleaned and staging rules, "shop_cache" cleaned only, "ledger"
  # none. Each reads its source from <KEY>_DB_URL and is restored, in the
  # environment `staging`, to the database in <KEY>_STAGING_DB_URL. The
  # environment is on when TEST_STAGING_RESTORES_ENABLED is exactly "true".
  def declare_databases(*keys, restore: true, **options)
    keys.each do |key|
      @harbor_file["databases"][key] = { "source_env" => "#{key.upcase}_DB_URL", "variants_env" => "#{key.upcase}_BACKUP_VARIANTS" }
                                       .merge(options.deep_stringify_keys)
      declare_restore("staging", key, target_env: "#{key.upcase}_STAGING_DB_URL") if restore
    end
    write_harbor_file(@harbor_file)
  end

  def declare_environment(key, **options)
    defaults = key == "staging" ? { "name" => "Staging", "enabled_env" => STAGING_SWITCH } : {}
    @harbor_file["restore_environments"][key] = defaults.merge("restores" => []).merge(options.deep_stringify_keys)
    write_harbor_file(@harbor_file)
  end

  def declare_restore(environment, database, **options)
    declare_environment(environment) unless @harbor_file["restore_environments"].key?(environment)
    @harbor_file["restore_environments"][environment]["restores"] << { "database" => database }.merge(options.deep_stringify_keys)
    write_harbor_file(@harbor_file)
  end

  def enable_staging_restores! = ENV[STAGING_SWITCH] = "true"

  def staging_restore(database) = Harbor::DbOps::Database.find!(database).restore_in!("staging")
end

# Stands in for the orca command for code that builds its own client
# (Harbor::Orca.runner): a server that makes worktrees and terminals by
# counting, remembers every command, and can be told to refuse one.
class FakeOrcaServer
  attr_reader :calls
  # Whether a terminal asked about has nothing running in it any more.
  attr_accessor :exited

  def initialize
    @calls = []
    @refusals = {}
    @terminals = 0
    @exited = false
  end

  # Refuse the next `command` ("terminal create") with Orca's error `code`.
  def refuse(command, code: "runtime_unavailable") = @refusals[command] = code

  def call(argv, timeout:)
    @calls << argv
    command = argv[1, 2].join(" ")
    if (code = @refusals.delete(command))
      return [ JSON.generate("ok" => false, "error" => { "code" => code, "message" => "refused: #{code}" }), "", 1 ]
    end
    [ JSON.generate("ok" => true, "result" => answer(command, argv)), "", 0 ]
  end

  # The commands run so far, as "worktree create", "terminal close"…
  def commands = calls.map { |argv| argv[1, 2].join(" ") }

  # The command line given to each terminal, in order.
  def terminal_commands = calls.select { |argv| argv[1, 2] == %w[terminal create] }.map { |argv| argv[argv.index("--command") + 1] }

  private

  def answer(command, argv)
    case command
    when "worktree create"
      name = argv[argv.index("--name") + 1]
      { "worktree" => { "id" => "repo-1::/work/#{name}", "path" => "/work/#{name}", "branch" => name } }
    when "terminal create"
      { "terminal" => { "handle" => "term-#{@terminals += 1}", "worktreeId" => argv[argv.index("--worktree") + 1] } }
    when "terminal wait"
      { "wait" => { "satisfied" => exited, "status" => exited ? "exited" : "running" } }
    when "status --json" then { "runtime" => { "appVersion" => "1.4.257", "state" => "ready" } }
    when "repo add"
      path = argv[argv.index("--path") + 1]
      { "repo" => { "id" => "repo-1", "displayName" => File.basename(path), "path" => path } }
    else {}
    end
  end
end

# Stands in for Conductor's API for code that builds its own client
# (Harbor::ConductorCloud.transport): it makes workspaces and sessions by
# counting, holds a transcript a test adds to, remembers every request, and
# can be told to be unavailable or to refuse one. Nothing here reaches the
# real service.
class FakeConductorCloud
  Request = Struct.new(:verb, :path, :params, :headers, keyword_init: true) do
    def to_s = "#{verb} #{path}"
  end

  attr_reader :requests
  # What the workspace and the session say when asked how they are.
  attr_accessor :workspace, :session, :session_error, :workspace_error, :lifecycle
  # Answer every request with a 503 while true.
  attr_accessor :down
  # How many messages one page of the transcript holds.
  attr_accessor :page_size
  # What GET /v0/workspaces lists.
  attr_accessor :listed

  def initialize
    @requests = []
    @refusals = {}
    @transcript = []
    @made = 0
    @workspace = "ready"
    @session = "working"
    @page_size = 100
    @listed = []
  end

  # Refuse the next request that is `what` ("POST /v0/workspaces").
  def refuse(what, code: 400, message: "refused") = @refusals[what] = [ code, message ]

  # The agent wrote these events: each becomes a transcript message.
  def say(*events) = events.each { |event| add("agent", { "rawPayload" => event }) }

  # Conductor's echo of a prompt.
  def prompted(text = "the prompt") = add("userMessage", { "text" => text })

  def add(type, content) = @transcript << { "id" => "m-#{@transcript.size + 1}", "type" => type, "content" => content }

  def sent = requests.map(&:to_s)

  def last(what) = requests.reverse.find { |request| request.to_s == what }

  def call(request)
    params = request.body.present? ? JSON.parse(request.body) : URI.decode_www_form(request.uri.query.to_s).to_h
    seen = Request.new(verb: request.method, path: request.uri.path, params:, headers: request.to_hash.transform_values(&:first))
    @requests << seen
    return [ 503, JSON.generate("userMessage" => "Service unavailable") ] if down
    if (refusal = @refusals.delete(seen.to_s))
      return [ refusal.first, JSON.generate("userMessage" => refusal.last) ]
    end
    answer = answer(seen)
    answer == :missing ? [ 404, JSON.generate("userMessage" => "not found") ] : [ 200, JSON.generate(answer) ]
  end

  private

  def answer(request)
    case request.to_s
    when "POST /v0/workspaces"
      @made += 1
      { "workspaceId" => "ws-#{@made}", "sessionId" => "sess-#{@made}", "deepLink" => "conductor://workspace/ws-#{@made}",
        "initialMessage" => { "messageId" => "m-0", "state" => "queued" } }
    when "GET /v0/workspaces" then { "data" => listed, "hasMore" => false }
    when "GET /v0/sections" then { "data" => [], "hasMore" => false }
    when %r{\AGET /v0/workspaces/[^/]+/status\z}
      return :missing if workspace == "missing"
      { "status" => workspace, "lifecycleStep" => lifecycle, "errorMessage" => workspace_error }.compact
    when %r{\AGET /v0/sessions/[^/]+/status\z} then { "status" => session, "errorMessage" => session_error }.compact
    when %r{\AGET /v0/sessions/[^/]+/messages\z}
      from = request.params["after"] ? @transcript.index { |message| message["id"] == request.params["after"] }.to_i + 1 : 0
      rest = @transcript[from..] || []
      { "data" => rest.first(page_size), "hasMore" => rest.size > page_size }
    when %r{\APOST /v0/sessions/[^/]+/cancel\z} then { "status" => "idle", "canceledQueuedMessages" => 0 }
    when %r{\APOST /v0/workspaces/[^/]+/archive\z} then { "status" => "archived" }
    else {}
    end
  end
end

# A Conductor Cloud runtime for the agent of HarborAgentSessions, the
# stand-in for Conductor's API, and an API key in the environment.
module HarborConductorCloud
  KEY = "CONDUCTOR_API_KEY".freeze

  def self.included(base)
    base.setup do
      @conductor_key = ENV[KEY]
      ENV[KEY] = "test-conductor-key"
      @conductor = FakeConductorCloud.new
      Harbor::ConductorCloud.transport = @conductor
      @conductor_config = [ Harbor.config.conductor_cloud_user_agent, Harbor.config.conductor_cloud_models ]
    end
    base.teardown do
      @conductor_key ? ENV[KEY] = @conductor_key : ENV.delete(KEY)
      Harbor::ConductorCloud.transport = nil
      Harbor.config.conductor_cloud_user_agent, Harbor.config.conductor_cloud_models = @conductor_config
    end
  end

  def cloud_runtime(**attributes)
    Harbor::Runtime.create!({ key: "cloud", name: "Cloud", backend: "conductor_cloud", max_concurrent: 2,
                              config: { "repository_url" => "https://github.com/acme/app" } }.merge(attributes))
  end
end

# An agent with a model, a workspace and an Orca runtime to run on, a folder
# for logs, and a stand-in for Orca. Everything is put back afterwards.
module HarborAgentSessions
  HOOKS = %i[agent_session_env agent_session_preamble agent_session_finished claude_bin codex_bin log_location run_reported].freeze

  def self.included(base)
    base.include HarborTestConfig
    base.include ActiveJob::TestHelper
    base.setup do
      [ Harbor::Automation, Harbor::RunEvent, Harbor::TaskAssignment, Harbor::AgentDocument, Harbor::AgentSetting, Harbor::Agent,
        Harbor::WorkspaceProfileRuntime, Harbor::WorkspaceProfile, Harbor::DatabaseBackup, Harbor::WebhookEvent, Harbor::Run,
        Harbor::Runtime, Harbor::ModelChoice, Harbor::ModelAlias, Harbor::ModelProvider ].each(&:delete_all)
      HARBOR_TEST_REDIS.with { |r| r.call("KEYS", "harbor:test:slots:*").each { |k| r.call("DEL", k) } }
      Harbor::Setting.set!(:runner_url, "https://harbor.example.com")
      @harbor_hooks = HOOKS.index_with { |name| Harbor.config.public_send(name) }
      @logs = Dir.mktmpdir("harbor-logs")
      Harbor.config.log_location = ->(path) { File.join(@logs, path) }
      @orca = FakeOrcaServer.new
      Harbor::Orca.runner = @orca

      @anthropic = Harbor::ModelProvider.create!(key: "anthropic")
      @openai = Harbor::ModelProvider.create!(key: "openai")
      @alias = Harbor::ModelAlias.create!(name: "Thinking", model_choices_attributes: [
        { model_provider: @anthropic, model: "claude-sonnet-5-5", effort: "medium", position: 0 } ])
      @choice = @alias.model_choices.first
      @runtime = Harbor::Runtime.create!(key: "laptop", name: "Laptop", backend: "orca", max_concurrent: 2,
                                         config: { "repo" => "name:app" })
      @workspace = Harbor::WorkspaceProfile.create!(name: "Default", workspace_profile_runtimes_attributes: [
        { runtime: @runtime, position: 0 } ])
      @agent = Harbor::Agent.create!(key: "writer", name: "Writer", system_prompt: "You write.", model_alias: @alias,
                                     workspace_profile: @workspace, max_agents: 2, max_workspaces: 2,
                                     tools: { "allowed" => %w[Read Grep Glob] })
    end
    base.teardown do
      Harbor::Orca.runner = nil
      @harbor_hooks.each { |name, value| Harbor.config.public_send("#{name}=", value) }
      FileUtils.remove_entry(@logs) if @logs && File.exist?(@logs)
    end
  end

  def new_run(**attributes) = Harbor::Run.create!({ agent_key: "writer", skill: "writer.fix", status: "queued" }.merge(attributes))

  # A session started on the stand-in Orca.
  def start_session(run: new_run, prompt: "Fix the test.", **options)
    Harbor::AgentSession.start!(run:, agent: @agent, prompt:, runtime: @runtime, choice: @choice, **options)
  end

  def runner_headers(run, type = "application/octet-stream")
    { "Authorization" => "Bearer #{Harbor::RunToken.generate(run)}", "Content-Type" => type }
  end

  # Posts a piece of output as the runner would, at the offset the run is at
  # unless one is given.
  def post_output(run, bytes, offset: run.reload.runner_state["received"].to_i, attempt: nil)
    query = { offset:, attempt: }.compact.to_query
    post "/harbor/runner/runs/#{run.id}/log?#{query}", params: bytes, headers: runner_headers(run)
  end

  def post_result(run, exit_status, signalled: false, attempt: nil)
    post "/harbor/runner/runs/#{run.id}/result#{"?attempt=#{attempt}" if attempt}",
         params: { exit_status:, signalled: }, headers: { "Authorization" => "Bearer #{Harbor::RunToken.generate(run)}" }, as: :json
  end

  def ndjson(*events) = events.map { |event| "#{JSON.generate(event)}\n" }.join

  def live_log(run) = Harbor::LiveLog.read(run.live_log_path).to_s

  def raw_stream(run) = File.binread(Harbor::LiveLog.absolute(run.raw_log_path))
end

# A site with environment recipes: a config file of its own declaring them
# (the scripts are the real ones in test/fixtures/recipes), a folder the
# scripts write what they were given into, and an "Orca (per workspace)"
# runtime on the recipe `sandbox`. Include it after HarborAgentSessions.
# Nothing here starts a machine or an Orca server.
module HarborMachines
  RECIPES = File.expand_path("fixtures/recipes", __dir__)

  def self.included(base)
    base.setup do
      Harbor::Machine.delete_all
      @recipe_env = ENV["RECIPE_TEST_DIR"]
      @recipe_dir = Dir.mktmpdir("harbor-recipes")
      ENV["RECIPE_TEST_DIR"] = @recipe_dir
      @recipe_config = Harbor.config.config_file
      @recipe_config_dir = Dir.mktmpdir("harbor-config")
      Harbor.config.config_file = File.join(@recipe_config_dir, "harbor.yml")
      declare_recipes("sandbox" => recipe)
      Harbor::Machines.beat = 0.1
      Harbor::Machines::Provisioner.ready_wait = 0
      @sandbox = Harbor::Runtime.create!(key: "sandbox", name: "Sandbox", backend: "orca_per_workspace", max_concurrent: 2,
                                         config: { "recipe" => "sandbox" })
    end
    base.teardown do
      Harbor::Machines.beat = nil
      Harbor::Machines::Provisioner.ready_wait = nil
      Harbor.config.config_file = @recipe_config
      Harbor::ConfigFile.reload!
      Harbor::EnvironmentRecipes.reset!
      @recipe_env ? ENV["RECIPE_TEST_DIR"] = @recipe_env : ENV.delete("RECIPE_TEST_DIR")
      [ @recipe_dir, @recipe_config_dir ].each { |dir| FileUtils.remove_entry(dir) if dir && File.exist?(dir) }
      Harbor::Machine.delete_all
    end
  end

  def script(name) = File.join(RECIPES, "#{name}.sh")

  # A recipe's declaration, from the fixture scripts' names.
  def recipe(create: "create-ok", destroy: "destroy-ok", **more)
    { "name" => "Test sandbox", "create" => script(create), "destroy" => (destroy == "none" ? "none" : script(destroy)) }.merge(more.stringify_keys)
  end

  # Write the config file: a hash of recipes, or the file's text.
  def declare_recipes(recipes)
    File.write(Harbor.config.config_file, recipes.is_a?(String) ? recipes : { "environment_recipes" => recipes }.to_yaml)
    Harbor::ConfigFile.reload!
    Harbor::EnvironmentRecipes.reset!
  end

  # What the scripts were run as, in order: "create", "destroy"…
  def recipe_calls = File.exist?(File.join(@recipe_dir, "calls")) ? File.readlines(File.join(@recipe_dir, "calls"), chomp: true) : []

  # The ORCA_ variables a step was given.
  def recipe_env(step) = File.readlines(File.join(@recipe_dir, "#{step}.env"), chomp: true).to_h { |line| line.split("=", 2) }

  # The lifecycle JSON the last destroy read on stdin.
  def destroy_payload = JSON.parse(File.read(File.join(@recipe_dir, "destroy.json")))

  def machine_of(run) = Harbor::Machine.find_by(run_id: run.id)

  # The pairing code the fixture create step makes for a run's machine.
  def pairing_code(run) = "orca://pair?code=SECRET-#{machine_of(run).instance_id}"

  def start_machine_session(run: new_run, prompt: "Fix the test.", **options)
    Harbor::AgentSession.start!(run:, agent: @agent, prompt:, runtime: @sandbox, choice: @choice, **options)
  end

  # Runs the queued jobs that make machines, or remove them.
  def provision! = perform_enqueued_jobs(only: Harbor::Machines::ProvisionJob)
  def destroy! = perform_enqueued_jobs(only: Harbor::Machines::DestroyJob)

  # A session whose machine is up and whose command has started.
  def running_machine_session(**options)
    run = start_machine_session(**options)
    provision!
    run.reload
  end

  def process_alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH
    false
  end
end

# Workflows: empty tables, the registry as Harbor ships it (put back after a
# test that registers its own), the master switch on, and a way to run a
# workflow run forward without a queue.
module HarborWorkflows
  HOOKS = %i[workflow_class workflow_run_class user_class workflow_params workflow_starter workflow_subject workflow_manual_start
             workflow_event_data workflow_run_url workflow_run_finished workflow_step_retry workflow_run_cancel].freeze

  def self.included(base)
    # Once: its setup empties the settings, which a module included earlier
    # may have filled.
    base.include HarborTestConfig unless base < HarborTestConfig
    base.include ActiveJob::TestHelper
    base.setup do
      [ Harbor::WorkflowWait, Harbor::WorkflowStepRun ].each(&:delete_all)
      Harbor::Run.where.not(workflow_run_id: nil).delete_all
      Harbor::Workflow.update_all(current_version_id: nil)
      [ Harbor::WorkflowRun, Harbor::WorkflowVersion, Harbor::Workflow ].each(&:delete_all)
      @workflow_registry = Harbor::Workflows.snapshot
      @workflow_hooks = HOOKS.index_with { |name| Harbor.config.public_send(name) }
      Harbor::Setting.set!(:workflows_enabled, true)
    end
    base.teardown do
      Harbor::Workflows.restore!(@workflow_registry)
      @workflow_hooks.each { |name, value| Harbor.config.public_send("#{name}=", value) }
      clear_enqueued_jobs
    end
  end

  # Accepts the definition as a braced hash, or as bare string keys (which
  # Ruby hands over as keywords).
  def workflow(definition = nil, mode: "live", key: "wf-#{SecureRandom.hex(3)}", **bare)
    definition ||= bare.transform_keys(&:to_s)
    workflow = Harbor::Workflow.new(key:, name: key.titleize, mode:)
    _, errors = workflow.save_definition!(definition)
    assert_empty errors
    workflow
  end

  def start_workflow(workflow, input: {}, **options)
    Harbor::Workflows.start!(workflow, trigger: { "kind" => "manual", "sender" => "Sam" }, kind: "manual", input:, **options)
  end

  # Run AdvanceJob (and the advances it queues) until the queue is quiet.
  def drain(run)
    10.times do
      jobs = enqueued_jobs.select { |job| job["job_class"] == "Harbor::Workflows::AdvanceJob" }
      break if jobs.empty?
      enqueued_jobs.reject! { |job| job["job_class"] == "Harbor::Workflows::AdvanceJob" }
      jobs.each { |job| Harbor::Workflows::AdvanceJob.perform_now(*ActiveJob::Arguments.deserialize(job["arguments"])) }
    end
    run.reload
  end

  def step_of(run, key) = run.step_runs.reload.select { |step| step.step_key == key }.last

  # The Run a step dispatched, finished as an agent would finish it.
  def finish_step_run(run, step_key, text:, ok: true)
    agent_run = run.runs.where(workflow_step_key: step_key).order(:id).last
    assert agent_run, "expected #{step_key} to have dispatched a Run"
    agent_run.finish!(status: ok ? "ok" : "error", output: { "text" => text, "exit_code" => ok ? 0 : 1 }, error: (text unless ok))
  end

  # A step type of the test's own: records what it was given and finishes on
  # the spot, as a host's action would.
  class Recorder
    class << self
      attr_reader :seen

      def reset! = @seen = []

      def start(_engine, _step, step_run, input)
        (@seen ||= []) << input["message"]
        raise ArgumentError, "told to fail" if input["message"] == "fail"
        step_run.finish!(status: "ok", output: { "said" => input["message"] })
        :done
      end
    end
  end

  # Registers the "say" action, run by Recorder; it runs in a dry run only
  # when `side_effect: false` is given.
  def register_say(**options)
    Recorder.reset!
    Harbor::Workflows.register_step "action", action: "say", label: "Say", group: "Test", icon: "bell", color: "#000000",
      description: "Records a message.", fields: [ { name: "message", label: "Message", kind: "text" } ],
      outputs: [ [ "said", "string", "" ] ], runner: "HarborWorkflows::Recorder", **options
  end

  def said = Recorder.seen
end

# A model alias to judge with, an agent whose runs are judged, a folder for
# logs, and the hooks and registry a host fills, put back afterwards.
module HarborQuality
  HOOKS = %i[scorer_class proposal_class scorer_judge scorer_judge_wait proposal_drafter site_name log_location log_path].freeze

  def self.included(base)
    base.include HarborTestConfig
    base.include ActiveJob::TestHelper
    base.setup do
      [ Harbor::ScorerResult, Harbor::Proposal, Harbor::Scorer, Harbor::RunEvent, Harbor::TaskAssignment, Harbor::AgentDocument,
        Harbor::Agent, Harbor::WebhookEvent, Harbor::DatabaseBackup, Harbor::Run, Harbor::ModelChoice, Harbor::ModelAlias,
        Harbor::ModelProvider ].each(&:delete_all)
      Harbor::Proposals.reset!
      @quality_hooks = HOOKS.index_with { |name| Harbor.config.public_send(name) }
      @logs = Dir.mktmpdir("harbor-logs")
      Harbor.config.log_location = ->(path) { File.join(@logs, path) }
      @provider = Harbor::ModelProvider.create!(key: "anthropic")
      @alias = Harbor::ModelAlias.create!(name: "Quick", model_choices_attributes: [ { model_provider: @provider, model: "claude-haiku-5-5" } ])
      @agent = Harbor::Agent.create!(key: "writer", name: "Wren", system_prompt: "Be careful.", model_alias: @alias)
    end
    base.teardown do
      clear_enqueued_jobs
      Harbor::Proposals.reset!
      @quality_hooks.each { |name, value| Harbor.config.public_send("#{name}=", value) }
      FileUtils.remove_entry(@logs) if @logs && File.exist?(@logs)
    end
  end

  def new_scorer(**attributes)
    Harbor::Scorer.create!({ name: "Ran the tests #{SecureRandom.hex(3)}", judge_instructions: "Did it run the tests?", model_alias: @alias,
                             sample_rate: 0, pass_threshold: 1.0,
                             classifications: [ { "label" => "pass", "score" => 1.0 }, { "label" => "partial", "score" => 0.5 },
                                                { "label" => "fail", "score" => 0.0 } ] }.merge(attributes))
  end

  # A finished agent run with a transcript: one a scorer can judge.
  def agent_run(**attributes)
    Harbor::Run.create!({ agent_key: "writer", task_type: "review", skill: "writer.review", status: "ok",
                          raw_log_path: "writer/run.ndjson" }.merge(attributes))
  end

  def failure(scorer, agent_key: "writer", scored_at: 1.day.ago, **attributes)
    Harbor::ScorerResult.create!({ scorer:, run: agent_run(agent_key:), status: "ok", passed: false, classification: "fail", score: 0,
                                   reasoning: "No test run after the last edit.", scored_at: }.merge(attributes))
  end
end

# Overview and Velocity: empty tables, nothing declared by a host (put back
# afterwards), four task types, two agents and one assignment, and ways to
# make a workflow, an automation and a finished run.
module HarborOverviewSetup
  def self.included(base)
    base.include HarborTestConfig
    base.setup do
      [ Harbor::StageNote, Harbor::ScorerResult, Harbor::Proposal, Harbor::Scorer, Harbor::ReviewCheckRun, Harbor::ReviewRound,
        Harbor::ReviewRuleVersion, Harbor::ReviewRule, Harbor::WorkflowWait, Harbor::WorkflowStepRun ].each(&:delete_all)
      Harbor::Run.delete_all
      Harbor::Workflow.update_all(current_version_id: nil)
      [ Harbor::WorkflowRun, Harbor::WorkflowVersion, Harbor::Workflow, Harbor::Automation, Harbor::TaskAssignment, Harbor::AgentDocument,
        Harbor::AgentSetting, Harbor::Agent, Harbor::WorkspaceProfileRuntime, Harbor::WorkspaceProfile, Harbor::Runtime,
        Harbor::ModelChoice, Harbor::ModelAlias, Harbor::ModelProvider ].each(&:delete_all)
      @overview = Harbor::Overview.snapshot
      @velocity = Harbor::Velocity.snapshot
      @workflow_registry = Harbor::Workflows.snapshot
      @markdown = Harbor.config.markdown
      Harbor::Overview.reset!
      Harbor::Velocity.reset!
      Harbor::TaskTypes.reset!
      Harbor::TaskTypes.declare "review"
      Harbor::TaskTypes.declare "rebase", fallback: "review"
      Harbor::TaskTypes.declare "triage", default_agent: "planner"
      Harbor::TaskTypes.declare "audit"

      provider = Harbor::ModelProvider.create!(key: "anthropic")
      @alias = Harbor::ModelAlias.create!(name: "Thinking", model_choices_attributes: [
        { model_provider: provider, model: "claude-sonnet-5-5", effort: "high", position: 0 } ])
      @writer = Harbor::Agent.create!(key: "writer", name: "Wren", system_prompt: "Write plainly.", model_alias: @alias)
      @planner = Harbor::Agent.create!(key: "planner", name: "Piper", system_prompt: "Plan.")
      Harbor::TaskAssignment.create!(task_type: "review", agent_key: "writer")
    end
    base.teardown do
      Harbor::Overview.restore!(@overview)
      Harbor::Velocity.restore!(@velocity)
      Harbor::Workflows.restore!(@workflow_registry)
      Harbor.config.markdown = @markdown
      Harbor::TaskTypes.reset!
    end
  end

  def workflow(key, name, definition, mode: "live", **attrs)
    Harbor::Workflow.new(key:, name:, mode:, **attrs).tap do |record|
      _, errors = record.save_definition!(definition)
      raise errors.join("; ") if errors.any?
    end
  end

  def agent_step(agent) = { "key" => "work", "type" => "agent", "name" => "Do it", "agent" => agent, "prompt" => "Go." }

  def manual(steps) = { "triggers" => [ { "kind" => "manual" } ], "steps" => steps }

  def automation(key, name, **attrs)
    Harbor::Automation.create!({ key:, name:, kind: "agent", agent_key: "writer", prompt: "Do it.", trigger_kind: "schedule",
                                 cron: "0 3 * * 6" }.merge(attrs))
  end

  def finished(task_type, minutes:, cost: nil, status: "ok", started: 2.days.ago, **attrs)
    Harbor::Run.create!({ task_type:, status:, trigger_source: "webhook", started_at: started, created_at: started,
                          ended_at: started + minutes.minutes, cost_usd_actual: cost }.merge(attrs))
  end

  def declare_stages
    Harbor::Overview.stage "triage", title: "Triage", summary: "A ticket is read.", task_types: %w[triage],
                                     automations: %w[sweep], starts_on: ->(trigger) { trigger["kind"] == "ticket" }
    Harbor::Overview.stage "review", title: "Review", summary: "The change is read.", task_types: %w[review rebase],
                                     claims: %w[reviewing]
    Harbor::Overview.stage "ship", title: "Ship", summary: "It goes out."
  end
end
