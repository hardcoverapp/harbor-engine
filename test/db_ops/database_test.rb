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
    assert_equal "staging", Harbor::DbOps::Database.find!("shop").staging_variant
    assert_equal "cleaned", Harbor::DbOps::Database.find!("shop_cache").staging_variant
    assert_equal "SHOP_CACHE_STAGING_DB_URL", Harbor::DbOps::Database.find!("shop_cache").staging_env
    assert_raises(Harbor::DbOps::Database::Error) { Harbor::DbOps::Database.find!("unknown") }
  end

  test "a database declared without a variants key or a staging key has neither" do
    Harbor::Databases.declare "plain", source_env: "PLAIN_DB_URL"
    ENV["PLAIN_DB_URL"] = "postgres://user:secret@production/plain"
    ENV["PLAIN_BACKUP_VARIANTS"] = "cleaned"
    ENV["PLAIN_STAGING_DB_URL"] = "postgres://admin:pw@staging/plain"
    database = Harbor::DbOps::Database.find!("plain")
    assert_equal [ "full" ], database.variants
    assert_not database.staging_configured?
    assert_raises(Harbor::DbOps::Target::Error) { database.validate_staging! }
  end

  test "MySQL databases get full backups only and never refresh staging" do
    declare_databases "blog"
    ENV["BLOG_DB_URL"] = "mysql://backup:pw@mysql.example/blog"
    database = Harbor::DbOps::Database.find!("blog")
    assert database.mysql?
    assert_equal [ "full" ], database.variants
    assert database.assert_fresh!
    assert_raises(Harbor::DbOps::Database::Error) { database.staging_variant }
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
      assert_not database.staging_configured?
      error = assert_raises(Harbor::DbOps::Database::Error) { database.staging_variant }
      assert_match "Storefront's own database", error.message
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

  test "staging refuses every protected source even with the override" do
    ENV["LEDGER_STAGING_DB_URL"] = ENV["SHOP_DB_URL"]
    ENV["TEST_ALLOW_UNSAFE_RESTORE"] = "true"
    error = assert_raises(Harbor::DbOps::Target::Error) { Harbor::DbOps::Database.find!("ledger").validate_staging! }
    assert_match "refusing to destroy", error.message
  end

  test "staging refuses the app's own database, by DATABASE_URL and by Rails's config, even with the override" do
    ENV["TEST_ALLOW_UNSAFE_RESTORE"] = "true"
    ENV["LEDGER_STAGING_DB_URL"] = "postgres://other:pw@app-db.internal/app_production"
    assert_raises(Harbor::DbOps::Target::Error) { Harbor::DbOps::Database.find!("ledger").validate_staging! }

    own = ActiveRecord::Base.connection_db_config.configuration_hash
    ENV["LEDGER_STAGING_DB_URL"] = "postgres://someone:pw@#{own[:host] || 'localhost'}:#{own[:port] || 5432}/#{own[:database]}"
    error = assert_raises(Harbor::DbOps::Database::Error) { Harbor::DbOps::Database.find!("ledger").validate_staging! }
    assert_match "Refusing to destroy Storefront's own primary database", error.message
  end

  test "staging must name itself disposable unless the host's ENV switch says otherwise" do
    ENV["LEDGER_STAGING_DB_URL"] = "postgres://admin:pw@qa-box/scratch"
    error = assert_raises(Harbor::DbOps::Target::Error) { Harbor::DbOps::Database.find!("ledger").validate_staging! }
    assert_match "Set TEST_ALLOW_UNSAFE_RESTORE=true", error.message
    ENV["TEST_ALLOW_UNSAFE_RESTORE"] = "true"
    assert Harbor::DbOps::Database.find!("ledger").validate_staging!
  end

  test "a staging target shared with another database is refused" do
    ENV["SHOP_STAGING_DB_URL"] = "postgres://admin:pw@staging/shared"
    ENV["LEDGER_STAGING_DB_URL"] = "postgres://admin:pw@staging/shared"
    error = assert_raises(Harbor::DbOps::Database::Error) { Harbor::DbOps::Database.find!("ledger").validate_staging! }
    assert_match "overlaps another database's staging target", error.message
    ENV["SHOP_STAGING_DB_URL"] = "postgres://admin:pw@staging/shop"
    assert Harbor::DbOps::Database.find!("ledger").validate_staging!
  end

  test "staging restores are off until switched on, by the setting or the ENV key a host names for it" do
    ENV["LEDGER_STAGING_DB_URL"] = "postgres://admin:pw@staging/ledger"
    Harbor::Setting.reset!(:database_staging_restores)
    assert_not Harbor::DbOps::Database.staging_restores_enabled?
    error = assert_raises(Harbor::DbOps::Database::Error) { Harbor::DbOps::Database.find!("ledger").validate_staging! }
    assert_match "switched off", error.message

    Harbor.config.env_fallback :database_staging_restores, "TEST_STAGING_RESTORES"
    ENV["TEST_STAGING_RESTORES"] = "false"
    assert_not Harbor::DbOps::Database.staging_restores_enabled?
    ENV["TEST_STAGING_RESTORES"] = "maybe"
    assert_not Harbor::DbOps::Database.staging_restores_enabled?, "an unreadable value is off"
    ENV["TEST_STAGING_RESTORES"] = "true"
    assert Harbor::DbOps::Database.find!("ledger").validate_staging!
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
