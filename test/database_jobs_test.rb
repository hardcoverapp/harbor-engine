require "test_helper"

# Database operations as tracked runs: Harbor's restore job, and the base a
# host's own backup and refresh jobs inherit.
class HarborDatabaseJobsTest < ActiveSupport::TestCase
  include HarborDatabasesConfig

  class EchoJob < Harbor::DbOperationJob
    self.loader_slug = "db-backup"
    cattr_accessor :calls, default: []
    def operate(directory:, logger:)
      self.class.calls << directory
      { echoed: true }
    end
  end

  class RefusedJob < Harbor::DbOperationJob
    self.loader_slug = "db-backup"
    def operate(directory:, logger:) = raise(Skipped, "not today")
  end

  setup do
    [ Harbor::DatabaseBackup, Harbor::Run ].each(&:delete_all)
    EchoJob.calls = []
    @logs = Dir.mktmpdir("harbor-logs")
    @log_location = Harbor.config.log_location
    Harbor.config.log_location = ->(path) { File.join(@logs, path) }
    declare_databases "ledger"
    ENV["LEDGER_DB_URL"] = "postgres://user:secret@production/ledger"
    ENV["LEDGER_STAGING_DB_URL"] = "postgres://admin:pw@staging/ledger"
    folder = File.join(@backup_root, "ledger/cleaned/1700000000000")
    FileUtils.mkdir_p(folder)
    File.write(File.join(folder, "toc.dat"), "toc")
    @backup = Harbor::DatabaseBackup.create!(database_key: "ledger", variant: "cleaned", path: "ledger/cleaned/1700000000000",
                                             bytes: 3, sha256: Harbor::DbOps::LocalStore.digest(folder))
  end

  teardown do
    Harbor.config.log_location = @log_location
    FileUtils.remove_entry(@logs)
  end

  test "an operation runs under the backup folder's lock, in a scratch folder there, and records its result" do
    run = Harbor::Run.create!(loader: "db-backup", trigger_source: "manual")
    EchoJob.perform_now(run.id)
    assert_equal [ "ok", { "echoed" => true } ], [ run.reload.status, run.output ]
    assert_equal File.realpath(@backup_root), File.realpath(File.dirname(EchoJob.calls.first))
    assert_not File.exist?(EchoJob.calls.first), "the scratch folder is removed"
    assert_includes Harbor::LiveLog.read(run.live_log_path), "[db-backup] starting"
  end

  test "a second operation while one holds the lock is a skipped run, not an error" do
    run = Harbor::Run.create!(loader: "db-backup", trigger_source: "manual")
    Harbor::DbOps::Workspace.with_lock { EchoJob.perform_now(run.id) }
    assert_equal "skipped", run.reload.status
    assert_match "Another database operation is running", run.error
    assert_empty EchoJob.calls
  end

  test "a finished run is never run again" do
    run = Harbor::Run.create!(loader: "db-backup", trigger_source: "manual")
    run.finish!(status: "ok")
    EchoJob.perform_now(run.id)
    assert_empty EchoJob.calls
  end

  test "a job's own skip and its errors are recorded on the run and not raised" do
    run = Harbor::Run.create!(loader: "db-backup", trigger_source: "manual")
    RefusedJob.perform_now(run.id)
    assert_equal [ "skipped", "not today" ], [ run.reload.status, run.error ]

    failing = Harbor::Run.create!(loader: "database-restore", trigger_source: "manual", input: { "environment" => "staging", "database" => "nowhere", "backup_id" => @backup.id })
    enable_staging_restores!
    Harbor::DatabaseRestoreJob.perform_now(failing.id)
    assert_equal "error", failing.reload.status
    assert_match "Unknown database", failing.error
  end

  test "the restore job is skipped while staging restores are off, before anything is read" do
    run = restore_run
    Harbor::DatabaseRestoreJob.perform_now(run.id)
    assert_equal "skipped", run.reload.status
    assert_match "switched off", run.error
  end

  test "the restore job refuses a run that names no environment, or one the file doesn't declare" do
    enable_staging_restores!
    touched = []
    with_stub(Harbor::DbOps::StagingLock, :with_lock, ->(*, **) { touched << :lock }) do
      [ {}, { "environment" => "" }, { "environment" => "production" } ].each do |extra|
        run = Harbor::Run.create!(loader: "database-restore", trigger_source: "manual", input: { "database" => "ledger", "backup_id" => @backup.id }.merge(extra))
        Harbor::DatabaseRestoreJob.perform_now(run.id)
        assert_equal "error", run.reload.status, extra.inspect
        assert_match(/No restore environment was named|Unknown restore environment production/, run.error)
      end
      # A database the environment doesn't list has no target there.
      declare_databases "metrics", restore: false
      run = Harbor::Run.create!(loader: "database-restore", trigger_source: "manual", input: { "environment" => "staging", "database" => "metrics", "backup_id" => @backup.id })
      Harbor::DatabaseRestoreJob.perform_now(run.id)
      assert_match "metrics is not restored in staging", run.reload.error
    end
    assert_empty touched
  end

  test "nothing in a run's input can name a target or switch an environment on" do
    ENV["ELSEWHERE_DB_URL"] = "postgres://admin:pw@elsewhere/ledger"
    input = { "environment" => "staging", "database" => "ledger", "backup_id" => @backup.id, "enabled" => true,
              "target_env" => "ELSEWHERE_DB_URL", "target" => ENV["ELSEWHERE_DB_URL"], "backup" => "full" }
    off = Harbor::Run.create!(loader: "database-restore", trigger_source: "manual", input:)
    Harbor::DatabaseRestoreJob.perform_now(off.id)
    assert_equal "skipped", off.reload.status

    enable_staging_restores!
    locked = []
    lock = ->(target, **, &block) { locked << target.redacted; block.call(target, {}) }
    on = Harbor::Run.create!(loader: "database-restore", trigger_source: "manual", input:)
    with_restore_stubs(lock) { Harbor::DatabaseRestoreJob.perform_now(on.id) }
    assert_equal "ok", on.reload.status, on.error
    assert_equal [ "admin@staging:5432/ledger" ], locked, "the file's target, not the input's"
  end

  test "the restore job checks, verifies, then replaces staging with the chosen backup" do
    enable_staging_restores!
    calls = []
    lock = ->(target, **, &block) { calls << [ :lock, target.redacted ]; block.call(target, {}) }
    run = restore_run
    with_stub(Harbor::DbOps::Pg, :server_version_major, 16) do
      with_stub(Harbor::DbOps::Pg, :assert_client_new_enough!, true) do
        with_stub(Harbor::DbOps::StagingLock, :with_lock, lock) do
          with_stub(Harbor::DbOps::Pg, :reset_schemas, ->(*, **) { calls << :reset }) do
            with_stub(Harbor::DbOps::Pg, :restore_file, ->(_target, path, **) { calls << [ :restore, path ] }) do
              Harbor::DatabaseRestoreJob.perform_now(run.id)
            end
          end
        end
      end
    end
    assert_equal "ok", run.reload.status, run.error
    assert_equal [ [ :lock, "admin@staging:5432/ledger" ], :reset, [ :restore, @backup.folder ] ], calls
    assert_equal({ "database" => "ledger", "backup_id" => @backup.id, "target" => "admin@staging:5432/ledger" }, run.output)
  end

  test "the restore job refuses a full backup and a changed dump, and touches nothing" do
    enable_staging_restores!
    touched = []
    lock = ->(*, **) { touched << :lock }
    with_stub(Harbor::DbOps::Pg, :server_version_major, 16) do
      with_stub(Harbor::DbOps::Pg, :assert_client_new_enough!, true) do
        with_stub(Harbor::DbOps::StagingLock, :with_lock, lock) do
          File.write(File.join(@backup.folder, "toc.dat"), "changed")
          changed = restore_run
          Harbor::DatabaseRestoreJob.perform_now(changed.id)
          assert_equal "error", changed.reload.status
          assert_match "checksum or size mismatch", changed.error

          @backup.update!(variant: "full")
          full = restore_run
          Harbor::DatabaseRestoreJob.perform_now(full.id)
          assert_equal "error", full.reload.status
          assert_match "Only cleaned or staging backups", full.error
        end
      end
    end
    assert_empty touched
  end

  # --- restoring a whole environment ---

  test "an environment restore checks every entry and verifies every dump before the first drop" do
    environment_with_two_databases
    events = []
    lock = ->(target, **, &block) { events << [ :lock, target.database ]; block.call(target, {}) }
    version = ->(target, **) { events << [ :checked, target.database ]; 16 }
    run = environment_run
    with_restore_stubs(lock, version:) { Harbor::EnvironmentRestoreJob.perform_now(run.id) }
    assert_equal "ok", run.reload.status, run.error
    assert_equal [ [ :checked, "ledger" ], [ :checked, "shop" ], [ :lock, "ledger" ], [ :lock, "shop" ] ], events
    assert_equal [ { "database" => "ledger", "backup_id" => @backup.id, "target" => "admin@staging:5432/ledger" },
                   { "database" => "shop", "backup_id" => @shop.id, "target" => "admin@staging:5432/shop" } ], run.output["restored"]
  end

  test "one refused entry, bad dump, stale or missing backup leaves every database of the environment untouched" do
    environment_with_two_databases
    touched = []
    lock = ->(*, **) { touched << :lock }
    attempt = lambda do
      run = environment_run
      with_restore_stubs(lock) { Harbor::EnvironmentRestoreJob.perform_now(run.id) }
      [ run.reload.status, run.error ]
    end

    ENV["SHOP_STAGING_DB_URL"] = ENV["LEDGER_DB_URL"]
    assert_match "refusing to destroy", attempt.call.last, "the second entry's target is a source"
    ENV["SHOP_STAGING_DB_URL"] = ENV["LEDGER_STAGING_DB_URL"]
    assert_match "overlaps another restore's target", attempt.call.last
    ENV["SHOP_STAGING_DB_URL"] = "postgres://admin:pw@staging/shop"

    File.write(File.join(@shop.folder, "toc.dat"), "changed")
    assert_match "checksum or size mismatch", attempt.call.last
    File.write(File.join(@shop.folder, "toc.dat"), "toc")

    @shop.update!(created_at: 9.days.ago)
    assert_match "refusing to restore stale data", attempt.call.last
    @shop.destroy!
    assert_equal [ "error", "Harbor::Databases::Error: No staging backup for Shop" ], attempt.call
    assert_empty touched
  end

  test "an environment restore uses each entry's kind: never full unless the entry names it" do
    environment_with_two_databases
    # Shop has staging rules and names no kind, so only a staging dump will do.
    @shop.update!(variant: "full")
    cleaned = Harbor::DatabaseBackup.create!(database_key: "shop", variant: "cleaned", path: "shop/cleaned/1700000000000", bytes: 3, sha256: "x")
    FileUtils.mkdir_p(cleaned.folder)
    File.write(File.join(cleaned.folder, "toc.dat"), "toc")
    run = environment_run
    with_restore_stubs(->(*, **) { flunk "restored" }) { Harbor::EnvironmentRestoreJob.perform_now(run.id) }
    assert_match "No staging backup for Shop", run.reload.error

    declare_environment "recovery", enabled: true, restores: [ { database: "shop", backup: "full", target_env: "SHOP_RECOVERY_DB_URL" } ]
    ENV["SHOP_RECOVERY_DB_URL"] = "postgres://admin:pw@recovery/shop"
    restored = []
    lock = ->(target, **, &block) { restored << target.redacted; block.call(target, {}) }
    run = environment_run("recovery")
    with_restore_stubs(lock) { Harbor::EnvironmentRestoreJob.perform_now(run.id) }
    assert_equal "ok", run.reload.status, run.error
    assert_equal [ "admin@recovery:5432/shop" ], restored
    assert_equal [ @shop.id ], run.output["restored"].map { |entry| entry["backup_id"] }
  end

  test "an environment restore is skipped while it is off or has no targets, and says which entries it left out" do
    environment_with_two_databases
    ENV[STAGING_SWITCH] = "false"
    run = environment_run
    Harbor::EnvironmentRestoreJob.perform_now(run.id)
    assert_equal [ "skipped", "Staging restores are switched off: #{STAGING_SWITCH} must be true where this app runs" ], [ run.reload.status, run.error ]

    enable_staging_restores!
    ENV.delete("SHOP_STAGING_DB_URL")
    restored = []
    lock = ->(target, **, &block) { restored << target.redacted; block.call(target, {}) }
    run = environment_run
    with_restore_stubs(lock) { Harbor::EnvironmentRestoreJob.perform_now(run.id) }
    assert_equal "ok", run.reload.status, run.error
    assert_equal [ "admin@staging:5432/ledger" ], restored, "an entry with no target is left out, not sent somewhere else"
    assert_includes Harbor::LiveLog.read(run.live_log_path), "Shop: SHOP_STAGING_DB_URL is not set, so it is not restored"

    ENV.delete("LEDGER_STAGING_DB_URL")
    run = environment_run
    Harbor::EnvironmentRestoreJob.perform_now(run.id)
    assert_equal [ "skipped", "No staging database URLs configured" ], [ run.reload.status, run.error ]

    run = Harbor::Run.create!(loader: "nowhere-restore", trigger_source: "manual", input: { "environment" => "nowhere" })
    Harbor::EnvironmentRestoreJob.perform_now(run.id)
    assert_equal [ "error", "Harbor::Databases::Error: Unknown restore environment nowhere" ], [ run.reload.status, run.error ]
  end

  private
    def environment_with_two_databases
      enable_staging_restores!
      declare_databases "shop"
      ENV["SHOP_DB_URL"] = "postgres://user:secret@production/shop"
      ENV["SHOP_STAGING_DB_URL"] = "postgres://admin:pw@staging/shop"
      folder = File.join(@backup_root, "shop/staging/1700000000000")
      FileUtils.mkdir_p(folder)
      File.write(File.join(folder, "toc.dat"), "toc")
      @shop = Harbor::DatabaseBackup.create!(database_key: "shop", variant: "staging", path: "shop/staging/1700000000000",
                                             bytes: 3, sha256: Harbor::DbOps::LocalStore.digest(folder))
    end

    def environment_run(key = "staging")
      Harbor::Run.create!(loader: "#{key}-restore", trigger_source: "manual", input: { "environment" => key })
    end

    def with_restore_stubs(lock, version: 16, &block)
      with_stub(Harbor::DbOps::Pg, :server_version_major, version) do
        with_stub(Harbor::DbOps::Pg, :assert_client_new_enough!, true) do
          with_stub(Harbor::DbOps::StagingLock, :with_lock, lock) do
            with_stub(Harbor::DbOps::Pg, :reset_schemas, true) do
              with_stub(Harbor::DbOps::Pg, :restore_file, true, &block)
            end
          end
        end
      end
    end

    def restore_run
      Harbor::Run.create!(loader: "database-restore", trigger_source: "manual", input: { "environment" => "staging", "database" => "ledger", "backup_id" => @backup.id })
    end
end
