require "test_helper"

# The Databases page inside a host's layout: the declared databases with their
# backups, and the guards in front of every operation it can start.
class HarborDatabasePagesTest < ActionDispatch::IntegrationTest
  include HarborDatabasesConfig

  setup do
    [ Harbor::DatabaseBackup, Harbor::Run ].each(&:delete_all)
    declare_databases "ledger", "metrics"
    Harbor::Databases.declare "app", own: true, owner: "Storefront"
    Harbor.config.backup_host_root = "/Volumes/backups/databases"
    ENV["LEDGER_DB_URL"] = "postgres://reader:secret@production/ledger"
    ENV["LEDGER_STAGING_DB_URL"] = "postgres://admin:pw@staging/ledger"
    enable_staging_restores!
    @started = []
    Harbor.config.database_operation = lambda do |operation, user:, input:|
      @started << [ operation, user&.name, input ]
      Harbor::Run.create!(loader: operation, trigger_source: "manual", input: input.merge(loader: operation))
    end
    @backup = Harbor::DatabaseBackup.create!(database_key: "ledger", variant: "cleaned", path: "ledger/cleaned/1700000000000",
                                             bytes: 3, sha256: "checksum", copies: { "local" => {}, "r2" => { "bucket" => "dev-dumps" } })
    @full = Harbor::DatabaseBackup.create!(database_key: "ledger", variant: "full", path: "ledger/full/1700000000000",
                                           bytes: 3, sha256: "checksum")
    [ @backup, @full ].each do |backup|
      FileUtils.mkdir_p(backup.folder)
      File.write(File.join(backup.folder, "toc.dat"), "toc")
    end
    post "/login", params: { name: "Sam Settings" }
  end

  test "it needs a login, and its page can be switched off" do
    delete "/logout"
    get harbor.databases_path
    assert_redirected_to "/login"
    post harbor.backup_all_databases_path
    assert_redirected_to "/login"
    assert_empty @started

    post "/login", params: { name: "Sam Settings" }
    Harbor::Setting.set!(:page_database, "false")
    get harbor.databases_path
    assert_response :not_found
    post harbor.backup_all_databases_path
    assert_response :not_found
    assert_empty @started
  end

  test "with no databases declared the page says so and nothing fails" do
    Harbor::Databases.reset!
    get harbor.databases_path
    assert_response :success
    assert_select "[data-no-databases]", text: /No databases are declared/
    assert_select "[role=alert]", count: 0
    assert_select "section[id^=database-]", count: 0
    get harbor.databases_path(tab: "operations")
    assert_response :success
  end

  test "the databases tab shows configuration and backup status without credentials" do
    get harbor.databases_path
    assert_response :success
    assert_select "h1", "Databases"
    assert_select "[data-harbor-nav] a[aria-current=page]", text: "Databases"
    assert_includes response.body, "/Volumes/backups/databases"
    assert_includes response.body, "ledger/cleaned/1700000000000"
    # Every kind gets its own list, and each backup shows where it's stored.
    assert_select "#database-ledger-full[data-backups='1']"
    assert_select "#database-ledger-cleaned[data-backups='1']"
    assert_select "#database-ledger-cleaned [data-copy=local][data-state=present]", text: "✅"
    assert_select "#database-ledger-cleaned [data-copy=cloud][data-state=present]", text: "✅"
    assert_select "#database-ledger-full [data-copy=local][data-state=present]", text: "✅"
    assert_select "#database-ledger-full [data-copy=cloud][data-state=none]", text: "–"
    assert_select "#database-metrics-full", text: /No full backups yet/
    assert_includes response.body, "Set METRICS_DB_URL"
    # The app's own database is listed like the rest, full backups only.
    assert_select "#database-app", text: /Storefront's own database · full backups only/
    assert_select "#database-app-cleaned", count: 0
    assert_select "input[name='confirmation']", count: 1
    assert_not_includes response.body, "reader:secret"
    assert_not_includes response.body, "postgres://"
    assert_select "[data-no-databases]", count: 0
  end

  test "without a mount to name, the folder shown is the one the app writes to" do
    Harbor.config.backup_host_root = nil
    get harbor.databases_path
    assert_includes response.body, @backup_root
  end

  test "the next scheduled runs come from the host" do
    get harbor.databases_path
    assert_select "p", text: "Next: Not scheduled", count: 2
    Harbor.config.database_schedule = ->(operation) { operation == "db-backup" ? Time.utc(2030, 1, 5, 8, 0) : nil }
    get harbor.databases_path
    assert_select "p", text: /Next: Jan 5, 8:00 AM/, count: 1
    assert_select "p", text: "Next: Not scheduled", count: 1
  end

  test "a running backup shows its progress on the operations tab" do
    Harbor::Run.create!(loader: "db-backup", trigger_source: "manual", status: "running", input: { "database" => "ledger" },
                        progress: { "label" => "Ledger · cleaned", "step" => 1, "steps" => 2, "bytes" => 3.gigabytes,
                                    "expected_bytes" => 5.gigabytes, "percent" => 60, "eta_seconds" => 720, "bytes_per_second" => 30.megabytes })
    get harbor.databases_path(tab: "operations")
    assert_response :success
    assert_select "[role=progressbar][aria-valuenow='60']"
    assert_includes response.body, "3 GB / ~5 GB"
    assert_includes response.body, "~12 min left"
  end

  test "a copy missing from the drive is flagged and can't be restored from" do
    FileUtils.rm_rf(@backup.folder)
    get harbor.databases_path
    assert_select "#database-ledger-cleaned [data-copy=local][data-state=missing]", text: "❌"
    assert_select "input[name='confirmation']", count: 0
  end

  test "configured buckets are listed with the kinds they hold" do
    get harbor.databases_path
    assert_includes response.body, "No bucket configured (TEST_BACKUP_S3_*)"
    ENV["TEST_BACKUP_S3_ENDPOINT"] = "https://acct.r2.cloudflarestorage.com"
    ENV["TEST_BACKUP_S3_CLEANED_BUCKET"] = "site-db-cleaned"
    ENV["TEST_BACKUP_S3_FULL_BUCKET"] = "site-db-full"
    get harbor.databases_path
    assert_includes response.body, "site-db-cleaned</span> · cleaned"
    assert_includes response.body, "site-db-full</span> · full and staging"
  end

  test "an invalid declaration is rendered without redirect loops" do
    Harbor::Databases.declare_each_time { |list| list.declare "../bad", source_env: "BAD_DB_URL" }
    get harbor.databases_path
    assert_response :success
    assert_select "[role='alert']", count: 1
  end

  test "backup starts an operation for the chosen database and kind, as the person who asked" do
    post harbor.backup_database_path("ledger"), params: { variant: "full" }
    assert_equal [ [ "db-backup", "Sam Settings", { database: "ledger", variant: "full" } ] ], @started
    assert_redirected_to harbor.databases_path(tab: "operations")
    follow_redirect!
    assert_select "[data-notice]", text: "Database operation queued."

    post harbor.backup_all_databases_path
    assert_equal [ "db-backup", "Sam Settings", {} ], @started.last
  end

  test "backup refuses an unknown database, one with no source, and a kind it doesn't have" do
    post harbor.backup_database_path("nowhere"), params: { variant: "full" }
    assert_redirected_to harbor.databases_path
    post harbor.backup_database_path("metrics"), params: { variant: "full" }
    follow_redirect!
    assert_select "[data-alert]", text: "METRICS_DB_URL is not configured"
    post harbor.backup_database_path("ledger"), params: { variant: "staging" }
    follow_redirect!
    assert_select "[data-alert]", text: "Unknown backup variant"
    assert_empty @started
  end

  test "restore requires database name confirmation" do
    post harbor.restore_database_path("ledger"), params: { backup_id: @backup.id, confirmation: "wrong" }
    assert_redirected_to harbor.databases_path
    assert_empty @started
    post harbor.restore_database_path("ledger"), params: { backup_id: @backup.id, confirmation: "ledger" }
    assert_equal [ [ "database-restore", "Sam Settings", { database: "ledger", backup_id: @backup.id } ] ], @started
  end

  test "cannot restore a full backup, another database's backup, or one missing from disk" do
    post harbor.restore_database_path("ledger"), params: { backup_id: @full.id, confirmation: "ledger" }
    post harbor.restore_database_path("metrics"), params: { backup_id: @backup.id, confirmation: "metrics" }
    FileUtils.rm_rf(@backup.folder)
    post harbor.restore_database_path("ledger"), params: { backup_id: @backup.id, confirmation: "ledger" }
    assert_redirected_to harbor.databases_path
    assert_empty @started
  end

  test "restore is refused when staging is a protected database or doesn't name itself disposable" do
    ENV["LEDGER_STAGING_DB_URL"] = ENV["LEDGER_DB_URL"]
    post harbor.restore_database_path("ledger"), params: { backup_id: @backup.id, confirmation: "ledger" }
    follow_redirect!
    assert_select "[data-alert]", text: /refusing to destroy reader@production:5432\/ledger/
    assert_not_includes response.body, "secret"

    ENV["LEDGER_STAGING_DB_URL"] = "postgres://admin:pw@qa-box/scratch"
    post harbor.restore_database_path("ledger"), params: { backup_id: @backup.id, confirmation: "ledger" }
    follow_redirect!
    assert_select "[data-alert]", text: /does not look like a disposable environment/
    assert_empty @started
  end

  test "with staging restores off nothing can be restored or refreshed, and the page says paused" do
    Harbor::Setting.set!(:database_staging_restores, "false")
    get harbor.databases_path
    assert_select "p.display", text: "Paused"
    assert_select "input[name='confirmation']", count: 0
    assert_select "form[action=?] button[disabled]", harbor.refresh_staging_databases_path
    post harbor.restore_database_path("ledger"), params: { backup_id: @backup.id, confirmation: "ledger" }
    post harbor.refresh_staging_databases_path
    follow_redirect!
    assert_select "[data-alert]", text: /Staging restores are switched off/
    assert_empty @started

    enable_staging_restores!
    post harbor.refresh_staging_databases_path
    assert_equal [ [ "staging-restore", "Sam Settings", {} ] ], @started
  end

  test "a host that starts no operations gets the page with no buttons, and the actions aren't there" do
    Harbor.config.database_operation = nil
    get harbor.databases_path
    assert_response :success
    assert_select "#database-ledger"
    assert_select "form[action=?]", harbor.backup_all_databases_path, count: 0
    assert_select "form[action=?]", harbor.backup_database_path("ledger"), count: 0
    assert_select "form[action=?]", harbor.refresh_staging_databases_path, count: 0
    assert_select "input[name='confirmation']", count: 0
    post harbor.backup_all_databases_path
    assert_response :not_found
    post harbor.restore_database_path("ledger"), params: { backup_id: @backup.id, confirmation: "ledger" }
    assert_response :not_found
  end

  test "two tabs: the databases, and the operations that ran" do
    op = Harbor::Run.create!(loader: "db-backup", trigger_source: "manual", status: "ok", input: { "database" => "ledger", "variant" => "cleaned" })
    other = Harbor::Run.create!(loader: "something-else", trigger_source: "manual", status: "ok")
    get harbor.databases_path
    assert_select "[data-tabs=databases] a[aria-current=page]", text: "Databases"
    assert_select "[data-tabs=databases] a[href=?]", harbor.databases_path(tab: "operations"), text: "Recent operations"
    assert_select "#database-operations", count: 0
    assert_select "#operation-#{op.id}", count: 0

    get harbor.databases_path(tab: "operations")
    assert_response :success
    assert_select "[data-tabs=databases] a[aria-current=page]", text: "Recent operations"
    assert_select "#operation-#{op.id}", text: /Db Backup\s+· ledger · cleaned/
    assert_select "#operation-#{other.id}", count: 0
    assert_select "#database-ledger", count: 0
  end

  test "the Databases tab never refreshes itself; operations do only while something runs" do
    get harbor.databases_path
    assert_select "[data-controller='harbor--poll']", count: 0
    get harbor.databases_path(tab: "operations")
    assert_select "[data-controller='harbor--poll']", count: 0

    Harbor::Run.create!(loader: "db-backup", trigger_source: "manual", status: "running", input: {})
    get harbor.databases_path
    assert_select "[data-controller='harbor--poll']", count: 0
    assert_select "[data-operation-running] a[href=?]", harbor.databases_path(tab: "operations")
    get harbor.databases_path(tab: "operations")
    assert_select "[data-controller='harbor--poll'][data-harbor--poll-interval-value='10']", count: 1
  end

  test "each backup row carries its kind as an icon chip, and the kinds are explained once" do
    get harbor.databases_path
    assert_select "[data-backup-legend] [data-backup-kind]", count: 3
    assert_select "[data-backup-legend]", text: /disaster recovery.*developers' laptops.*Refreshes staging/m
    assert_select "#database-ledger-cleaned tr[data-backup='#{@backup.id}'] [data-backup-kind=cleaned] svg"
    assert_select "#database-ledger-full tr[data-backup='#{@full.id}'] [data-backup-kind=full]", text: "Full"
    assert_select "#database-metrics-full [data-backup-kind=full]"

    Harbor.config.backup_kind_notes = { "staging" => "Staff keep their own rows." }
    get harbor.databases_path
    assert_select "[data-backup-legend]", text: /Staff keep their own rows\./
  end

  test "a kind with a bucket configured but no copy there is marked missing from the cloud" do
    ENV["TEST_BACKUP_S3_ENDPOINT"] = "https://acct.r2.cloudflarestorage.com"
    ENV["TEST_BACKUP_S3_FULL_BUCKET"] = "site-db-full"
    get harbor.databases_path
    assert_select "#database-ledger-full [data-copy=cloud][data-state=missing][title='Missing from Cloudflare R2']", text: "❌"
    assert_select "th[title='Cloudflare R2']", text: "Cloud"
  end
end
