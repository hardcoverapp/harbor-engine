require "test_helper"

# The registry a host declares its databases into.
class HarborDatabasesTest < ActiveSupport::TestCase
  include HarborDatabasesConfig

  test "nothing is declared until a host declares it, and nothing fails" do
    assert_empty Harbor::Databases.definitions
    assert_not Harbor::Databases.any?
    assert_empty Harbor::Databases.environments
    assert_empty Harbor::DbOps::Database.all
    assert_empty Harbor::DbOps::Environment.all
    assert_empty Harbor::Databases.problems
    assert_equal [ "This app" ], Harbor::DbOps::Database.protected_targets.map(&:label), "only the app's own database"
  end

  # --- the config file ---

  test "a missing file, an empty one and one with only comments declare nothing" do
    assert_not File.exist?(Harbor.config.config_file)
    assert_empty Harbor::Databases.definitions
    [ "", "# nothing yet\n", "databases:\nrestore_environments:\n" ].each do |text|
      write_harbor_file(text)
      assert_empty Harbor::Databases.definitions, text.inspect
      assert_empty Harbor::Databases.environments, text.inspect
    end
  end

  test "the file's default place is config/harbor.yml in the app, and a host may name another" do
    assert_equal Rails.root.join("config/harbor.yml"), Harbor::Configuration.new.config_file.call
    assert_equal Pathname(File.join(@config_dir, "harbor.yml")), Harbor::ConfigFile.path
    other = File.join(@config_dir, "other.yml")
    File.write(other, "databases:\n  ledger: { source_env: LEDGER_DB_URL }\n")
    Harbor.config.config_file = -> { other }
    assert_equal %w[ledger], Harbor::Databases.definitions.map(&:key)
    assert_equal other, Harbor::ConfigFile.label, "a file outside the app is named in full"
  end

  test "the file declares databases and environments by ENV key, in its order" do
    write_harbor_file(<<~YAML)
      databases:
        ledger:
          source_env: LEDGER_DB_URL
          variants_env: LEDGER_BACKUP_VARIANTS
          label: The Ledger
          freshness:
            entries: created_at
        shop:
          source_env: SHOP_DB_URL
          variants: [full, cleaned]
        app:
          own: true
          owner: Storefront
      restore_environments:
        staging:
          name: Staging
          enabled_env: STAGING_RESTORES_ENABLED
          restores:
            - database: ledger
              backup: cleaned
              target_env: LEDGER_STAGING_DB_URL
            - { database: shop, target_env: SHOP_STAGING_DB_URL }
        test-1:
          enabled: true
          restores:
            - { database: ledger, backup: cleaned, target_env: TEST1_LEDGER_DB_URL }
    YAML
    assert_empty Harbor::Databases.problems
    assert_equal %w[ledger shop app], Harbor::Databases.definitions.map(&:key)
    ledger, shop, app = Harbor::Databases.definitions
    assert_equal [ "LEDGER_DB_URL", "LEDGER_BACKUP_VARIANTS", nil, "The Ledger", { "entries" => "created_at" } ],
                 [ ledger.source_env, ledger.variants_env, ledger.variants, ledger.label, ledger.freshness ]
    assert_equal [ %w[full cleaned], nil ], [ shop.variants, shop.variants_env ]
    assert_equal [ true, "Storefront" ], [ app.own, app.owner ]
    assert_equal "Storefront", Harbor::Databases.app_name

    staging, test_1 = Harbor::Databases.environments
    assert_equal [ "staging", "Staging", nil, "STAGING_RESTORES_ENABLED" ], [ staging.key, staging.name, staging.enabled, staging.enabled_env ]
    assert_equal [ %w[ledger cleaned LEDGER_STAGING_DB_URL], [ "shop", nil, "SHOP_STAGING_DB_URL" ] ],
                 staging.restores.map { |restore| [ restore.database, restore.backup, restore.target_env ] }
    assert_equal [ "test-1", "Test 1", true, nil ], [ test_1.key, test_1.name, test_1.enabled, test_1.enabled_env ]
    assert_equal "test-1-restore", Harbor::DbOps::Environment.find!("test-1").operation
  end

  test "one database may feed several environments, and one environment may take several databases" do
    write_harbor_file(<<~YAML)
      databases:
        ledger: { source_env: LEDGER_DB_URL }
        shop: { source_env: SHOP_DB_URL }
      restore_environments:
        test-1: { enabled: true, restores: [ { database: ledger, backup: cleaned, target_env: TEST1_LEDGER_DB_URL } ] }
        test-2: { enabled: true, restores: [ { database: ledger, backup: cleaned, target_env: TEST2_LEDGER_DB_URL } ] }
        test-3:
          enabled: false
          restores:
            - { database: ledger, backup: cleaned, target_env: TEST3_LEDGER_DB_URL }
            - { database: shop, backup: cleaned, target_env: TEST3_SHOP_DB_URL }
        recovery: { enabled_env: RECOVERY_RESTORES, restores: [ { database: shop, backup: full, target_env: SHOP_RECOVERY_DB_URL } ] }
    YAML
    ENV["LEDGER_DB_URL"] = "postgres://reader:pw@production/ledger"
    (1..3).each { |n| ENV["TEST#{n}_LEDGER_DB_URL"] = "postgres://admin:pw@test-#{n}.internal/ledger" }
    ledger = Harbor::DbOps::Database.find!("ledger")
    assert_equal %w[test-1 test-2 test-3], ledger.restores.map { |entry| entry.environment.key }
    assert_equal %w[admin@test-1.internal:5432/ledger admin@test-2.internal:5432/ledger admin@test-3.internal:5432/ledger],
                 ledger.restores.map { |entry| entry.target.redacted }
    assert_equal %w[cleaned cleaned cleaned], ledger.restores.map(&:kind)
    assert_equal [ true, true, false, false ], Harbor::DbOps::Environment.all.map(&:enabled?)
    assert ledger.restore_in!("test-1").validate!
    assert ledger.restore_in!("test-2").validate!
    error = assert_raises(Harbor::Databases::Error) { ledger.restore_in!("test-3").validate! }
    assert_match "Test 3 restores are switched off: set enabled: true for test-3 in", error.message
    assert_equal %w[ledger shop], Harbor::DbOps::Environment.find!("test-3").restores.map { |entry| entry.database.key }
    recovery = Harbor::DbOps::Environment.find!("recovery").restore_of!("shop")
    assert_equal [ "full", "full" ], [ recovery.named_kind, recovery.kind ]
  end

  test "the file is run through ERB, and what its ERB reads from ENV is honoured each time" do
    write_harbor_file(<<~YAML)
      databases:
      <% ENV.fetch("TEST_DATABASES", "ledger").split(",").each do |key| -%>
        <%= key %>:
          source_env: <%= key.upcase %>_DB_URL
      <% end -%>
    YAML
    assert_equal %w[ledger], Harbor::Databases.definitions.map(&:key)
    assert_equal "LEDGER_DB_URL", Harbor::Databases.definitions.first.source_env
    ENV["TEST_DATABASES"] = "shop,ledger"
    assert_equal %w[shop ledger], Harbor::Databases.definitions.map(&:key)
    write_harbor_file("databases:\n  metrics: { source_env: METRICS_DB_URL }\n")
    assert_equal %w[metrics], Harbor::Databases.definitions.map(&:key), "an edited file is read again"
    Harbor::Databases.reload!
    assert_equal %w[metrics], Harbor::Databases.definitions.map(&:key)
  end

  test "a malformed file is an error naming the file, every time it is read, never an empty list" do
    bad = {
      "databases:\n  ledger: [unclosed\n" => /harbor\.yml: not valid YAML/,
      "- just\n- a list\n" => /harbor\.yml: must be a mapping of sections/,
      "databases: nope\n" => /harbor\.yml: databases must be a mapping/,
      "database:\n  ledger: { source_env: LEDGER_DB_URL }\n" => /harbor\.yml: unknown section database \(expected path, databases, restore_environments\)/,
      "databases:\n  <%= raise 'boom' %>\n" => /harbor\.yml: boom/,
      "databases:\n  <%= nope( %>\n" => /harbor\.yml: /,
      "databases:\n  ledger: { source_env: A_DB_URL }\n  ledger: { source_env: B_DB_URL }\n" => /harbor\.yml: databases\.ledger appears twice/
    }
    bad.each do |text, message|
      write_harbor_file(text)
      2.times do
        error = assert_raises(Harbor::Databases::Error, text) { Harbor::Databases.definitions }
        assert_match message, error.message
      end
      assert_match message, Harbor::Databases.problems.first
      assert_raises(Harbor::Databases::Error, text) { Harbor::DbOps::Database.all }
      assert_raises(Harbor::Databases::Error, text) { Harbor::DbOps::Database.protected_targets }
    end
  end

  test "an invalid database in the file is an error naming the file and the entry" do
    bad = {
      "Shop: { source_env: SHOP_DB_URL }" => "databases.Shop: Database names must use lowercase letters, numbers and underscores",
      "../escape: { source_env: SHOP_DB_URL }" => "databases.../escape: Database names must use",
      "shop: {}" => "databases.shop: Database shop needs source_env:",
      "shop:" => "databases.shop: Database shop needs source_env:",
      "shop: just-a-string" => "databases.shop: must be a mapping",
      "shop: { source_env: 'postgres://user:secret@production/shop' }" => "databases.shop: Database shop must name an ENV key",
      "shop: { source_env: SHOP_DB_URL, staging_env: SHOP_STAGING_DB_URL }" => "databases.shop: unknown key staging_env",
      "shop: { source_env: SHOP_DB_URL, sauce: 1 }" => "databases.shop: unknown key sauce",
      "shop: { source_env: SHOP_DB_URL, variants: [full, everything] }" => "databases.shop: Database shop: variants must list full, cleaned, staging",
      "shop: { source_env: SHOP_DB_URL, variants: full }" => "databases.shop: variants must be a list",
      "shop: { source_env: SHOP_DB_URL, variants: [full], variants_env: SHOP_KINDS }" => "databases.shop: Database shop: give variants or variants_env, not both",
      "shop: { source_env: SHOP_DB_URL, freshness: orders }" => "databases.shop: freshness must map tables",
      "shop: { own: yes please }" => "databases.shop: own must be true or false"
    }
    bad.each do |entry, message|
      write_harbor_file("databases:\n  #{entry}\n")
      error = assert_raises(Harbor::Databases::Error, entry) { Harbor::Databases.definitions }
      assert_includes error.message, "harbor.yml: #{message}", entry
      assert_not_includes error.message, "secret"
    end
  end

  test "an invalid environment or restore is an error naming the file and the entry" do
    databases = "databases:\n  ledger: { source_env: LEDGER_DB_URL }\n  shop: { source_env: SHOP_DB_URL }\n  app: { own: true, owner: Storefront }\n"
    ok = "{ database: ledger, target_env: LEDGER_STAGING_DB_URL }"
    bad = {
      "staging: { restores: [ { database: ledgre, target_env: X_DB_URL } ] }" => "restore_environments.staging.restores[0]: unknown database ledgre",
      "staging: { restores: [ { target_env: X_DB_URL } ] }" => "restore_environments.staging.restores[0]: needs database:",
      "staging: { restores: [ { database: ledger } ] }" => "restore_environments.staging.restores[0]: needs target_env:",
      "staging: { restores: [ { database: ledger, target_env: '' } ] }" => "restore_environments.staging.restores[0]: needs target_env:",
      "staging: { restores: [ { database: ledger, target_env: 'postgres://admin:secret@staging/ledger' } ] }" => "restores[0]: target_env must name an ENV key",
      "staging: { restores: [ { database: ledger, target: X_DB_URL, target_env: X_DB_URL } ] }" => "restores[0]: unknown key target",
      "staging: { restores: [ { database: ledger, target_env: X_DB_URL, must_contain: staging } ] }" => "restores[0]: unknown key must_contain",
      "staging: { restores: [ #{ok}, { database: shop, backup: everything, target_env: X_DB_URL } ] }" => "restores[1]: unknown backup kind \"everything\"",
      "staging: { restores: [ #{ok}, { database: shop, backup: , target_env: X_DB_URL } ] }" => "restores[1]: unknown backup kind \"\"",
      "staging: { restores: [ { database: app, backup: full, target_env: X_DB_URL } ] }" => "restores[0]: app is Storefront's own database: full backups only, never restored",
      "staging: { restores: [ #{ok}, { database: shop, target_env: LEDGER_STAGING_DB_URL } ] }" =>
        "restores[1]: target LEDGER_STAGING_DB_URL is already the target of restore_environments.staging (ledger)",
      "staging: { restores: [ #{ok} ] }\n  qa: { restores: [ { database: shop, target_env: LEDGER_STAGING_DB_URL } ] }" =>
        "restore_environments.qa.restores[0]: target LEDGER_STAGING_DB_URL is already the target of restore_environments.staging (ledger)",
      "staging: { restores: [ #{ok}, { database: ledger, target_env: OTHER_DB_URL } ] }" => "restores[1]: ledger is already restored in staging",
      "staging: { restores: #{ok} }" => "restore_environments.staging: restores must be a list",
      "staging: { restores: [ ledger ] }" => "restore_environments.staging.restores[0]: must be a mapping",
      "staging: { enabled: 'true', restores: [ #{ok} ] }" => "restore_environments.staging: enabled must be true or false",
      "staging: { enabled: 1, restores: [ #{ok} ] }" => "restore_environments.staging: enabled must be true or false",
      "staging: { enabled: true, enabled_env: ON, restores: [ #{ok} ] }" => "restore_environments.staging: give enabled or enabled_env, not both",
      "staging: { enabled_env: 'true', restores: [ #{ok} ] }\n  staging: { enabled: true }" => "restore_environments.staging appears twice",
      "staging: { enabled_env: , restores: [ #{ok} ] }" => "restore_environments.staging: enabled_env must name an ENV key",
      "staging: { enabled_env: true, restores: [ #{ok} ] }" => "restore_environments.staging: enabled_env must name an ENV key",
      "staging: { enbled: true, restores: [ #{ok} ] }" => "restore_environments.staging: unknown key enbled",
      "Staging: { restores: [ #{ok} ] }" => "restore_environments.Staging: environment keys use lowercase",
      "database: { restores: [ #{ok} ] }" => "restore_environments.database: database is a reserved name",
      "staging: nope" => "restore_environments.staging: must be a mapping"
    }
    bad.each do |entry, message|
      write_harbor_file("#{databases}restore_environments:\n  #{entry}\n")
      error = assert_raises(Harbor::Databases::Error, entry) { Harbor::Databases.environments }
      assert_includes error.message, "harbor.yml: ", entry
      assert_includes error.message, message, entry
      assert_not_includes error.message, "secret"
      assert_raises(Harbor::Databases::Error, entry) { Harbor::DbOps::Environment.all }
      assert_raises(Harbor::Databases::Error, entry) { Harbor::DbOps::Environment.find!("staging") }
      assert_equal 1, Harbor::Databases.problems.size, entry
    end
    # A restore mistake stops restores, not the backups of valid databases.
    assert_equal %w[ledger shop app], Harbor::Databases.definitions.map(&:key)
  end

  # --- declaring in Ruby ---

  test "a Ruby declaration names ENV keys, never URLs, and keeps its order after the file's" do
    declare_databases "ledger", restore: false
    Harbor::Databases.declare "shop", source_env: "SHOP_DB_URL", freshness: { orders: :created_at }
    Harbor::Databases.declare "app", own: true, owner: "Storefront"
    assert_equal %w[ledger shop app], Harbor::Databases.definitions.map(&:key)
    shop = Harbor::Databases.definitions.second
    assert_equal [ "SHOP_DB_URL", nil ], [ shop.source_env, shop.variants_env ]
    assert_equal({ "orders" => "created_at" }, shop.freshness)
    assert_equal "Storefront", Harbor::Databases.app_name
    # The file may restore a database that Ruby declared.
    declare_restore "staging", "shop", target_env: "SHOP_STAGING_DB_URL"
    assert_equal %w[shop], Harbor::DbOps::Environment.find!("staging").restores.map { |entry| entry.database.key }
  end

  test "a database declared in the file and in Ruby is an error, whichever way Ruby declares it" do
    declare_databases "ledger", restore: false
    Harbor::Databases.declare "ledger", source_env: "OTHER_DB_URL"
    error = assert_raises(Harbor::Databases::Error) { Harbor::Databases.definitions }
    assert_match(/Database ledger is declared in .*harbor\.yml and in Ruby/, error.message)

    Harbor::Databases.reset!
    Harbor::Databases.declare_each_time { |list| list.declare "ledger", source_env: "OTHER_DB_URL" }
    error = assert_raises(Harbor::Databases::Error) { Harbor::Databases.definitions }
    assert_match(/Database ledger is declared in .*harbor\.yml and in Ruby/, error.message)
  end

  test "names that couldn't be folders, duplicates, a database with no source and the removed staging_env are refused" do
    assert_raises(Harbor::Databases::Error) { Harbor::Databases.declare "../escape", source_env: "X" }
    assert_raises(Harbor::Databases::Error) { Harbor::Databases.declare "Shop", source_env: "X" }
    assert_raises(Harbor::Databases::Error) { Harbor::Databases.declare "shop" }
    assert_raises(Harbor::Databases::Error) { Harbor::Databases.declare "shop", source_env: "postgres://user:pw@production/shop" }
    error = assert_raises(Harbor::Databases::Error) { Harbor::Databases.declare "shop", source_env: "SHOP_DB_URL", staging_env: "SHOP_STAGING_DB_URL" }
    assert_match "staging_env: is gone. Declare what is restored where under restore_environments", error.message
    assert_raises(ArgumentError) { Harbor::Databases.declare "shop", source_env: "SHOP_DB_URL", sauce: 1 }
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
      print Harbor::DbOps::Database.all.size, Harbor::DbOps::Environment.all.size, Harbor::EnvironmentRestoreJob.superclass.superclass
    RUBY
    # No tool on the PATH: anything that tried to run one would fail here.
    env = { "PATH" => File.dirname(RbConfig.ruby), "RAILS_ENV" => "test" }
    out, status = Open3.capture2e(env, RbConfig.ruby, "-e", script, chdir: Harbor::Engine.root.to_s)
    assert status.success?, out
    assert_equal "00Harbor::TrackedJob", out.lines.last
  end
end
