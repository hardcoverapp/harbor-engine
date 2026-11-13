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

# A host with databases, for the Databases tests: the declarations, the ENV
# keys they name, a backup folder and the masking rules in test/fixtures.
# Everything is put back afterwards, ENV included.
module HarborDatabasesConfig
  CONFIG = %i[backup_root backup_host_root masking_rules_path greenmask_bin greenmask_pg_bin_path backup_bucket_env_prefix
              unsafe_restore_env staging_lock_role restore_application_name restore_spared_applications backup_kind_notes
              database_operation database_schedule].freeze
  RULES = File.expand_path("fixtures/masking", __dir__)

  def self.included(base)
    base.include HarborTestConfig
    base.include SingletonStub
    base.setup do
      @harbor_env = ENV.to_h
      @harbor_database_config = CONFIG.index_with { |name| Harbor.config.public_send(name) }
      Harbor::Databases.reset!
      @backup_root = Dir.mktmpdir("harbor-backups")
      Harbor.config.backup_root = @backup_root
      Harbor.config.masking_rules_path = RULES
      Harbor.config.backup_bucket_env_prefix = "TEST_BACKUP_S3"
      Harbor.config.unsafe_restore_env = "TEST_ALLOW_UNSAFE_RESTORE"
      ENV.delete("TEST_ALLOW_UNSAFE_RESTORE")
      # The app's own database as a deployed host names it. The suite's own
      # DATABASE_URL names a server with no database, which isn't a target.
      ENV["DATABASE_URL"] = "postgres://app:app-secret@app-db.internal:5432/app_production"
      ENV.keys.grep(/\ATEST_BACKUP_S3_/).each { |key| ENV.delete(key) }
    end
    base.teardown do
      ENV.replace(@harbor_env)
      @harbor_database_config.each { |name, value| Harbor.config.public_send("#{name}=", value) }
      Harbor::Databases.reset!
      FileUtils.remove_entry(@backup_root) if @backup_root && File.exist?(@backup_root)
    end
  end

  # "shop" has cleaned and staging rules, "shop_cache" cleaned only, "ledger"
  # none; each reads its URLs from <KEY>_DB_URL and <KEY>_STAGING_DB_URL.
  def declare_databases(*keys, **options)
    keys.each do |key|
      Harbor::Databases.declare key, source_env: "#{key.upcase}_DB_URL", staging_env: "#{key.upcase}_STAGING_DB_URL",
                                     variants_env: "#{key.upcase}_BACKUP_VARIANTS", **options
    end
  end

  def enable_staging_restores! = Harbor::Setting.set!(:database_staging_restores, "true")
end
