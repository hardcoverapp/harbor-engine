require "test_helper"

# The registry a host declares its databases into.
class HarborDatabasesTest < ActiveSupport::TestCase
  include HarborDatabasesConfig

  test "nothing is declared until a host declares it, and nothing fails" do
    assert_empty Harbor::Databases.definitions
    assert_not Harbor::Databases.any?
    assert_empty Harbor::DbOps::Database.all
    assert_equal [ "This app" ], Harbor::DbOps::Database.protected_targets.map(&:label), "only the app's own database"
  end

  test "a declaration names ENV keys, never URLs, and keeps its order" do
    Harbor::Databases.declare "shop", source_env: "SHOP_DB_URL", staging_env: "SHOP_STAGING_DB_URL", freshness: { orders: :created_at }
    Harbor::Databases.declare "app", own: true, owner: "Storefront"
    assert_equal %w[shop app], Harbor::Databases.definitions.map(&:key)
    shop = Harbor::Databases.definitions.first
    assert_equal [ "SHOP_DB_URL", "SHOP_STAGING_DB_URL", nil ], [ shop.source_env, shop.staging_env, shop.variants_env ]
    assert_equal({ "orders" => "created_at" }, shop.freshness)
    assert_equal "Storefront", Harbor::Databases.app_name
  end

  test "names that couldn't be folders, duplicates and a database with no source are refused" do
    assert_raises(Harbor::Databases::Error) { Harbor::Databases.declare "../escape", source_env: "X" }
    assert_raises(Harbor::Databases::Error) { Harbor::Databases.declare "Shop", source_env: "X" }
    assert_raises(Harbor::Databases::Error) { Harbor::Databases.declare "shop" }
    Harbor::Databases.declare "shop", source_env: "SHOP_DB_URL"
    assert_raises(Harbor::Databases::Error) { Harbor::Databases.declare "shop", source_env: "OTHER" }
  end

  test "a list declared in a block is read every time, after the fixed ones" do
    Harbor::Databases.declare "app", own: true
    Harbor::Databases.declare_each_time do |list|
      ENV.fetch("TEST_DATABASES", "").split(",").each { |key| list.declare key, source_env: "#{key.upcase}_DB_URL" }
    end
    assert_equal %w[app], Harbor::Databases.definitions.map(&:key)
    ENV["TEST_DATABASES"] = "shop,ledger"
    assert_equal %w[app shop ledger], Harbor::Databases.definitions.map(&:key)
    ENV["TEST_DATABASES"] = "shop,app"
    assert_raises(Harbor::Databases::Error) { Harbor::Databases.definitions }
    assert_equal "this app", Harbor::Databases.app_name, "a broken list doesn't break naming the app"
  end

  test "a config value may be a callable, read each time" do
    Harbor.config.backup_root = -> { ENV.fetch("TEST_BACKUP_PATH", "/var/backups") }
    assert_equal "/var/backups", Harbor::DbOps::LocalStore.root
    ENV["TEST_BACKUP_PATH"] = "/mnt/elsewhere"
    assert_equal "/mnt/elsewhere", Harbor::DbOps::LocalStore.root
  end

  test "the Databases settings are declared with safe defaults" do
    defaults = %w[database_backups_kept database_backup_jobs database_backup_min_free_gb
                  database_max_source_age_days database_max_backup_age_days database_connect_timeout database_upload_threads]
               .index_with { |key| Harbor::Setting.get(key) }
    assert_equal [ 4, 2, 40, 7, 8, 15, 4 ], defaults.values
    defaults.each_key { |key| assert_equal "Databases", Harbor::Settings.find(key).group }
    assert_raises(ArgumentError) { Harbor::Setting.set!(:database_backups_kept, "0") }
  end

  test "loading every class of the feature runs no database tool and loads no bucket gem" do
    script = <<~RUBY
      require "./test/dummy/config/environment"
      Rails.application.eager_load!
      abort "the bucket gem was loaded" if $LOADED_FEATURES.grep(/aws-sdk-s3/).any?
      print Harbor::DbOps::Database.all.size, Harbor::DbOperationJob.superclass
    RUBY
    # No tool on the PATH: anything that tried to run one would fail here.
    env = { "PATH" => File.dirname(RbConfig.ruby), "RAILS_ENV" => "test" }
    out, status = Open3.capture2e(env, RbConfig.ruby, "-e", script, chdir: Harbor::Engine.root.to_s)
    assert status.success?, out
    assert_equal "0Harbor::TrackedJob", out.lines.last
  end
end
