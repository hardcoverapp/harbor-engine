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
