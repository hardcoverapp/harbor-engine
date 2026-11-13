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
    else {}
    end
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
      [ Harbor::RunEvent, Harbor::TaskAssignment, Harbor::AgentDocument, Harbor::AgentSetting, Harbor::Agent,
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
