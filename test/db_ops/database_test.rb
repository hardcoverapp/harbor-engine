require "test_helper"

class HarborDbOpsDatabaseTest < ActiveSupport::TestCase
  include HarborDatabasesConfig

  setup do
    declare_databases "shop", "shop_cache", "ledger"
    Harbor::Databases.declare "app", own: true, owner: "Storefront"
    ENV["SHOP_DB_URL"] = "postgres://user:secret@production/shop"
    ENV["LEDGER_DB_URL"] = "postgres://user:secret@production/ledger"
    enable_staging_restores!
  end

  test "each database's kinds come from its rules files, or the ENV key its declaration names" do
    assert_equal %w[shop shop_cache ledger app], Harbor::DbOps::Database.all.map(&:key)
    database = Harbor::DbOps::Database.find!("ledger")
    assert database.configured?
    assert_equal "LEDGER_DB_URL", database.source_env
    assert_equal [ "full" ], database.variants, "no masking rules, so full only"
    ENV["LEDGER_BACKUP_VARIANTS"] = "full,cleaned"
    error = assert_raises(Harbor::DbOps::Database::Error) { database.variants }
    assert_match "cleaned backups need masking rules in", error.message
    assert_equal %w[full cleaned staging], Harbor::DbOps::Database.find!("shop").variants, "every kind with rules, by default"
    assert_equal %w[full cleaned], Harbor::DbOps::Database.find!("shop_cache").variants, "no staging rules for the cache"
    ENV["SHOP_BACKUP_VARIANTS"] = "cleaned"
    assert_equal %w[cleaned], Harbor::DbOps::Database.find!("shop").variants
    ENV["SHOP_BACKUP_VARIANTS"] = "full,everything"
    error = assert_raises(Harbor::DbOps::Database::Error) { Harbor::DbOps::Database.find!("shop").variants }
    assert_match "SHOP_BACKUP_VARIANTS must list", error.message
    ENV["SHOP_CACHE_BACKUP_VARIANTS"] = "full,staging"
    assert_raises(Harbor::DbOps::Database::Error) { Harbor::DbOps::Database.find!("shop_cache").variants }
    assert_equal "staging", staging_restore("shop").kind
    assert_equal "cleaned", staging_restore("shop_cache").kind
    assert_equal "SHOP_CACHE_STAGING_DB_URL", staging_restore("shop_cache").target_env
    assert_equal %w[staging], Harbor::DbOps::Database.find!("shop").restores.map { |entry| entry.environment.key }
    assert_raises(Harbor::DbOps::Database::Error) { Harbor::DbOps::Database.find!("unknown") }
  end

  test "a database declared without a variants key or a restore has neither" do
    Harbor::Databases.declare "plain", source_env: "PLAIN_DB_URL"
    ENV["PLAIN_DB_URL"] = "postgres://user:secret@production/plain"
    ENV["PLAIN_BACKUP_VARIANTS"] = "cleaned"
    ENV["PLAIN_STAGING_DB_URL"] = "postgres://admin:pw@staging/plain"
    database = Harbor::DbOps::Database.find!("plain")
    assert_equal [ "full" ], database.variants
    assert_empty database.restores
    assert_nil database.restore_in("staging")
    error = assert_raises(Harbor::DbOps::Database::Error) { database.restore_in!("staging") }
    assert_match "Plain is not restored in staging", error.message
  end

  test "the kinds may be listed in the file instead of an ENV key" do
    declare_databases "shop_two", restore: false, variants_env: nil, variants: %w[full]
    ENV["SHOP_TWO_DB_URL"] = "postgres://user:secret@production/shop_two"
    assert_equal [ "full" ], Harbor::DbOps::Database.find!("shop_two").variants
  end

  test "MySQL databases get full backups only and never refresh staging" do
    declare_databases "blog"
    ENV["BLOG_DB_URL"] = "mysql://backup:pw@mysql.example/blog"
    database = Harbor::DbOps::Database.find!("blog")
    assert database.mysql?
    assert_equal [ "full" ], database.variants
    assert database.assert_fresh!
    assert_raises(Harbor::DbOps::Database::Error) { database.restore_in!("staging").kind }
    ENV["BLOG_BACKUP_VARIANTS"] = "full,cleaned"
    assert_raises(Harbor::DbOps::Database::Error) { database.variants }
  end

  test "the app's own database is read from Rails's config, full only, never a staging target" do
    database = Harbor::DbOps::Database.find!("app")
    assert database.own?
    assert_equal "DATABASE_URL", database.source_env
    config = { host: "postgres", port: 5432, username: "app", password: "p@ss word", database: "app_production" }
    with_primary_config(config) do
      assert database.configured?
      source = database.source
      assert_equal [ "postgres", 5432, "app", "p@ss word", "app_production" ],
                   [ source.host, source.port, source.user, source.password, source.database ]
      assert_equal [ "full" ], database.variants
      assert_empty database.restores
      assert_raises(Harbor::DbOps::Database::Error) { database.restore_in!("staging") }
    end
    with_primary_config(database: "app_development") { assert_not database.configured?, "a socket connection can't be dumped" }
  end

  test "only databases declared with freshness tables are probed, with the setting's limit" do
    Harbor::Databases.declare "orders", source_env: "ORDERS_DB_URL", freshness: { "orders" => "created_at" }
    ENV["ORDERS_DB_URL"] = "postgres://user:secret@production/orders"
    Harbor::Setting.set!(:database_max_source_age_days, "3")
    seen = []
    probe = ->(target, probes:, max_age_days:, **) { seen << [ target.database, probes, max_age_days ]; true }
    with_stub(Harbor::DbOps::Freshness, :assert_fresh!, probe) do
      assert Harbor::DbOps::Database.find!("orders").assert_fresh!
      assert Harbor::DbOps::Database.find!("shop").assert_fresh!
    end
    assert_equal [ [ "orders", { "orders" => "created_at" }, 3 ] ], seen
  end

  # --- what a restore must never replace ---

  test "the protected set is every configured source and the app's own database" do
    with_primary_config(host: "postgres", port: 5432, username: "app", password: "pw", database: "app_production") do
      protected = Harbor::DbOps::Database.protected_targets.map(&:redacted)
      assert_equal [ "user@production:5432/shop", "user@production:5432/ledger", "app@postgres:5432/app_production",
                     "app@app-db.internal:5432/app_production" ], protected
    end
  end

  test "a restore refuses every declared source, whatever the target is called" do
    ENV["LEDGER_STAGING_DB_URL"] = ENV["SHOP_DB_URL"]
    error = assert_raises(Harbor::DbOps::Target::Error) { staging_restore("ledger").validate! }
    assert_match "refusing to destroy", error.message
    # The same database written another way is still that database.
    [ "postgres://other:pw@PRODUCTION:5432/Shop", "postgres://other:pw@production./sh%6Fp", "postgresql://x:y@production/shop?sslmode=require" ].each do |url|
      ENV["LEDGER_STAGING_DB_URL"] = url
      assert_raises(Harbor::DbOps::Target::Error, url) { staging_restore("ledger").validate! }
    end
    ENV["LEDGER_STAGING_DB_URL"] = "postgres://other:pw@production:5433/shop"
    assert staging_restore("ledger").validate!, "another port is another server"
  end

  test "a restore refuses the app's own database, by DATABASE_URL and by Rails's config" do
    ENV["LEDGER_STAGING_DB_URL"] = "postgres://other:pw@app-db.internal/app_production"
    assert_raises(Harbor::DbOps::Target::Error) { staging_restore("ledger").validate! }

    own = ActiveRecord::Base.connection_db_config.configuration_hash
    host = own[:host] || "localhost"
    port = own[:port] || 5432
    [ "#{host}:#{port}/#{own[:database]}", "#{host.upcase}:#{port}/#{own[:database].upcase}" ].each do |address|
      ENV["LEDGER_STAGING_DB_URL"] = "postgres://someone:pw@#{address}"
      error = assert_raises(Harbor::DbOps::Database::Error, address) { staging_restore("ledger").validate! }
      assert_match "Refusing to destroy Storefront's own primary database", error.message
    end
  end

  test "nothing about a target's name is checked: the file listing it is what allows it" do
    ENV["LEDGER_STAGING_DB_URL"] = "postgres://admin:pw@qa-box/scratch"
    assert staging_restore("ledger").validate!
    ENV["LEDGER_STAGING_DB_URL"] = "postgres://admin:pw@db.example/ledger_production_copy"
    assert staging_restore("ledger").validate!
    assert_not Harbor.config.respond_to?(:unsafe_restore_env), "there is no name rule left to override"
  end

  test "a target whose ENV key is unset or blank is refused, never defaulted" do
    entry = staging_restore("ledger")
    [ nil, "", "   " ].each do |value|
      value.nil? ? ENV.delete("LEDGER_STAGING_DB_URL") : ENV["LEDGER_STAGING_DB_URL"] = value
      assert_not entry.configured?, value.inspect
      error = assert_raises(Harbor::DbOps::Target::Error, value.inspect) { entry.validate! }
      assert_match "Ledger staging (LEDGER_STAGING_DB_URL) URL is blank", error.message
    end
    ENV["LEDGER_STAGING_DB_URL"] = "mysql://admin:pw@staging/ledger"
    error = assert_raises(Harbor::DbOps::Database::Error) { entry.validate! }
    assert_match "replaces PostgreSQL databases only", error.message
  end

  test "a target shared with another restore is refused, in the same environment or another" do
    ENV["SHOP_STAGING_DB_URL"] = "postgres://admin:pw@staging/shared"
    ENV["LEDGER_STAGING_DB_URL"] = "postgres://admin:pw@STAGING:5432/Shared"
    error = assert_raises(Harbor::DbOps::Database::Error) { staging_restore("ledger").validate! }
    assert_match "overlaps another restore's target: shop in staging (SHOP_STAGING_DB_URL)", error.message
    ENV["SHOP_STAGING_DB_URL"] = "postgres://admin:pw@staging/shop"
    assert staging_restore("ledger").validate!

    # Another environment, switched off, still owns its target.
    declare_restore "qa", "shop", target_env: "SHOP_QA_DB_URL"
    ENV["SHOP_QA_DB_URL"] = ENV["LEDGER_STAGING_DB_URL"]
    error = assert_raises(Harbor::DbOps::Database::Error) { staging_restore("ledger").validate! }
    assert_match "shop in qa (SHOP_QA_DB_URL)", error.message
  end

  test "an environment is off until the ENV key the file names is exactly true; no setting turns it on" do
    ENV["LEDGER_STAGING_DB_URL"] = "postgres://admin:pw@staging/ledger"
    environment = Harbor::DbOps::Environment.find!("staging")
    [ nil, "", "false", "TRUE", "True", "1", "yes", "on", " true", "true " ].each do |value|
      value.nil? ? ENV.delete(STAGING_SWITCH) : ENV[STAGING_SWITCH] = value
      assert_not environment.enabled?, value.inspect
    end
    error = assert_raises(Harbor::DbOps::Database::Error) { staging_restore("ledger").validate! }
    assert_match "Staging restores are switched off: #{STAGING_SWITCH} must be true", error.message
    assert_empty Harbor::Settings.all.select { |setting| setting.key.match?(/restore|environment|unsafe|target/) }, "no setting can stand in for the file"
    assert_not Harbor.config.respond_to?(:staging_restores_env)

    ENV[STAGING_SWITCH] = "true"
    assert staging_restore("ledger").validate!
  end

  test "an environment with a literal switch is on only for enabled: true, and one with neither is off" do
    declare_restore "qa", "shop", target_env: "SHOP_QA_DB_URL"
    ENV["SHOP_QA_DB_URL"] = "postgres://admin:pw@qa/shop"
    qa = -> { Harbor::DbOps::Environment.find!("qa") }
    assert_not qa.call.enabled?, "neither enabled nor enabled_env: off"
    assert_match "set enabled: true for qa in", qa.call.off_message
    ENV["QA_RESTORES_ENABLED"] = ENV["ENABLED"] = ENV["QA"] = "true"
    assert_not qa.call.enabled?, "no ENV key it didn't name turns it on"
    declare_environment "qa", enabled: false, restores: [ { database: "shop", target_env: "SHOP_QA_DB_URL" } ]
    assert_not qa.call.enabled?
    declare_environment "qa", enabled: true, restores: [ { database: "shop", target_env: "SHOP_QA_DB_URL" } ]
    assert qa.call.enabled?
    assert qa.call.restore_of!("shop").validate!
  end

  test "a restore uses the kind its entry names, and full only when named" do
    backup = ->(variant) { Harbor::DatabaseBackup.new(database_key: "shop", variant:, path: "shop/#{variant}/1700000000000") }
    unnamed = staging_restore("shop")
    assert_nil unnamed.named_kind
    assert_equal "staging", unnamed.kind
    assert_equal "cleaned", staging_restore("shop_cache").kind
    assert_equal [ false, true, true ], %w[full cleaned staging].map { |kind| unnamed.accepts?(backup.call(kind)) }
    error = assert_raises(Harbor::DbOps::Database::Error) { unnamed.assert_backup!(backup.call("full")) }
    assert_match "Only cleaned or staging backups can be restored to staging", error.message

    declare_restore "qa", "shop", backup: "cleaned", target_env: "SHOP_QA_DB_URL"
    declare_restore "recovery", "shop", backup: "full", target_env: "SHOP_RECOVERY_DB_URL"
    cleaned = Harbor::DbOps::Environment.find!("qa").restore_of!("shop")
    full = Harbor::DbOps::Environment.find!("recovery").restore_of!("shop")
    assert_equal [ "cleaned", "full" ], [ cleaned.kind, full.kind ]
    assert_equal [ false, true, false ], %w[full cleaned staging].map { |kind| cleaned.accepts?(backup.call(kind)) }
    assert_equal [ true, false, false ], %w[full cleaned staging].map { |kind| full.accepts?(backup.call(kind)) }
    error = assert_raises(Harbor::DbOps::Database::Error) { cleaned.assert_backup!(backup.call("full")) }
    assert_match "Only a cleaned backup can be restored to qa", error.message
    assert_raises(Harbor::DbOps::Database::Error) { full.assert_backup!(backup.call("staging")) }
    assert full.assert_backup!(backup.call("full"))
    other = Harbor::DatabaseBackup.new(database_key: "ledger", variant: "full", path: "ledger/full/1700000000000")
    assert_raises(Harbor::DbOps::Database::Error) { full.assert_backup!(other) }
  end

  test "libpq query overrides and malformed credentials cannot bypass guards or leak" do
    url = "postgres://user:secret@staging/staging?host=production&dbname=shop"
    assert_raises(Harbor::DbOps::Target::Error) { Harbor::DbOps::Target.new(url) }
    error = assert_raises(Harbor::DbOps::Target::Error) { Harbor::DbOps::Target.new("postgres://user:secret@bad host/db") }
    assert_not_includes error.message, "secret"
    encoded = Harbor::DbOps::Target.new("postgres://user:secret@production/sh%6Fp")
    assert encoded.same_server_and_db?(Harbor::DbOps::Database.find!("shop").source)
  end

  private
    def with_primary_config(hash, &block)
      config = Struct.new(:configuration_hash).new(hash)
      configurations = ActiveRecord::Base.configurations
      original = configurations.method(:configs_for)
      configs_for = ->(**options) { options[:name] == "primary" ? config : original.call(**options) }
      with_stub(configurations, :configs_for, configs_for, &block)
    end
end
