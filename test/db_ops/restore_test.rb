require "test_helper"

class HarborDbOpsRestoreTest < ActiveSupport::TestCase
  include HarborDatabasesConfig

  setup do
    declare_databases "time"
    ENV["TIME_DB_URL"] = "postgres://user:secret@production/time"
    ENV["TIME_STAGING_DB_URL"] = "postgres://user:secret@staging/time"
    enable_staging_restores!
    @dir = @backup_root
    folder = File.join(@dir, "time/cleaned/1700000000000")
    FileUtils.mkdir_p(folder)
    File.write(File.join(folder, "toc.dat"), "toc")
    File.write(File.join(folder, "1.dat.gz"), "data")
    @backup = Harbor::DatabaseBackup.create!(database_key: "time", variant: "cleaned", path: "time/cleaned/1700000000000",
                                    bytes: 7, sha256: Harbor::DbOps::LocalStore.digest(folder))
    @restore = Harbor::DbOps::Restore.new(logger: nil)
  end
  test "verify reads the dump folder in place" do
    assert_equal File.join(@dir, "time/cleaned/1700000000000"), @restore.verify(@backup)
  end

  test "a corrupt or missing dump fails before touching staging" do
    File.write(File.join(@backup.folder, "1.dat.gz"), "DATA")
    error = assert_raises(Harbor::DbOps::Pg::Error) { @restore.verify(@backup) }
    assert_match "checksum", error.message
    FileUtils.rm_rf(@backup.folder)
    error = assert_raises(Harbor::DbOps::Pg::Error) { @restore.verify(@backup) }
    assert_match "missing from disk", error.message
  end

  test "older single-file backups still restore" do
    legacy = Harbor::DatabaseBackup.create!(database_key: "time", variant: "cleaned", path: "time/2026-11-07_120000Z-cleaned",
                                    bytes: 4, sha256: Digest::SHA256.hexdigest("dump"))
    FileUtils.mkdir_p(legacy.folder)
    File.write(File.join(legacy.folder, "time.dump"), "dump")
    assert_equal File.join(legacy.folder, "time.dump"), @restore.verify(legacy)
  end

  test "preflight refuses another database's backup, full backups and a switched-off environment" do
    entry = staging_restore("time")
    @backup.update!(database_key: "shop")
    assert_raises(Harbor::DbOps::Database::Error) { @restore.preflight(entry, @backup) }
    @backup.update!(database_key: "time", variant: "full")
    error = assert_raises(Harbor::DbOps::Database::Error) { @restore.preflight(entry, @backup) }
    assert_match "Only cleaned or staging", error.message
    @backup.update!(variant: "staging")
    target = with_stub(Harbor::DbOps::Pg, :server_version_major, 16) { with_stub(Harbor::DbOps::Pg, :assert_client_new_enough!, true) { @restore.preflight(entry, @backup) } }
    assert target.same_server_and_db?(entry.target), "the target is the one the file names"
    @backup.update!(variant: "cleaned")
    ENV[STAGING_SWITCH] = "false"
    assert_raises(Harbor::DbOps::Database::Error) { @restore.preflight(entry, @backup) }
  end

  test "preflight refuses a target whose ENV key is unset before asking any server anything" do
    ENV.delete("TIME_STAGING_DB_URL")
    asked = []
    with_stub(Harbor::DbOps::Pg, :server_version_major, ->(*, **) { asked << :version; 16 }) do
      assert_raises(Harbor::DbOps::Target::Error) { @restore.preflight(staging_restore("time"), @backup) }
    end
    assert_empty asked
  end

  test "apply replaces the target and restores the dump under the lock" do
    entry = staging_restore("time")
    calls = []
    lock = ->(target, **, &block) { calls << :lock; block.call(target, {}) }
    with_stub(Harbor::DbOps::StagingLock, :with_lock, lock) do
      with_stub(Harbor::DbOps::Pg, :reset_schemas, ->(*, **) { calls << :reset }) do
        with_stub(Harbor::DbOps::Pg, :restore_file, ->(_target, path, **) { calls << [ :restore, path ] }) do
          @restore.apply(entry, @backup, @backup.folder, target: entry.target)
          @backup.update!(variant: "full")
          assert_raises(Harbor::DbOps::Database::Error) { @restore.apply(entry, @backup, @backup.folder, target: entry.target) }
          # The guards run again right before the destructive step.
          @backup.update!(variant: "cleaned")
          ENV[STAGING_SWITCH] = "false"
          assert_raises(Harbor::DbOps::Database::Error) { @restore.apply(entry, @backup, @backup.folder, target: entry.target) }
          enable_staging_restores!
          # A target handed in that is not the one the file names is refused.
          elsewhere = Harbor::DbOps::Target.new("postgres://user:secret@staging/somewhere_else")
          error = assert_raises(Harbor::DbOps::Database::Error) { @restore.apply(entry, @backup, @backup.folder, target: elsewhere) }
          assert_match "not the one TIME_STAGING_DB_URL names", error.message
          held = entry.target
          ENV["TIME_STAGING_DB_URL"] = "postgres://user:secret@staging/time_moved"
          assert_raises(Harbor::DbOps::Database::Error) { @restore.apply(entry, @backup, @backup.folder, target: held) }
          ENV["TIME_STAGING_DB_URL"] = ENV["TIME_DB_URL"]
          assert_raises(Harbor::DbOps::Target::Error) { @restore.apply(entry, @backup, @backup.folder, target: entry.target) }
        end
      end
    end
    assert_equal [ :lock, :reset, [ :restore, @backup.folder ] ], calls
  end

  test "a full backup is restored only by an entry that names full" do
    declare_environment "recovery", enabled: true, restores: [ { database: "time", backup: "full", target_env: "TIME_RECOVERY_DB_URL" } ]
    ENV["TIME_RECOVERY_DB_URL"] = "postgres://user:secret@recovery/time"
    @backup.update!(variant: "full")
    calls = []
    lock = ->(target, **, &block) { calls << target.redacted; block.call(target, {}) }
    with_stub(Harbor::DbOps::StagingLock, :with_lock, lock) do
      with_stub(Harbor::DbOps::Pg, :reset_schemas, true) do
        with_stub(Harbor::DbOps::Pg, :restore_file, true) do
          recovery = Harbor::DbOps::Environment.find!("recovery").restore_of!("time")
          @restore.apply(recovery, @backup, @backup.folder, target: recovery.target)
          staging = staging_restore("time")
          assert_raises(Harbor::DbOps::Database::Error) { @restore.apply(staging, @backup, @backup.folder, target: staging.target) }
          @backup.update!(variant: "cleaned")
          assert_raises(Harbor::DbOps::Database::Error) { @restore.apply(recovery, @backup, @backup.folder, target: recovery.target) }
        end
      end
    end
    assert_equal [ "user@recovery:5432/time" ], calls
  end

  test "a MySQL dump is never handed to a restore, even where full is named" do
    declare_environment "recovery", enabled: true, restores: [ { database: "time", backup: "full", target_env: "TIME_RECOVERY_DB_URL" } ]
    ENV["TIME_RECOVERY_DB_URL"] = "postgres://user:secret@recovery/time"
    recovery = Harbor::DbOps::Environment.find!("recovery").restore_of!("time")
    @backup.update!(variant: "full")
    File.write(File.join(@backup.folder, "time.sql.gz"), "sql")
    assert_raises(Harbor::DbOps::Database::Error) { recovery.assert_backup!(@backup) }
    FileUtils.rm(File.join(@backup.folder, "time.sql.gz"))
    ENV["TIME_DB_URL"] = "mysql://backup:pw@mysql.example/time"
    error = assert_raises(Harbor::DbOps::Database::Error) { recovery.assert_backup!(@backup) }
    assert_match "MySQL", error.message
  end

  test "shared scratch lock refuses simultaneous database operations" do
    Harbor::DbOps::Workspace.with_lock do
      assert_raises(Harbor::TrackedJob::Skipped) { Harbor::DbOps::Workspace.with_lock { flunk "second operation entered" } }
    end
    Harbor::DbOps::Workspace.with_lock do |dir|
      assert File.directory?(dir)
      assert File.basename(dir).start_with?("."), "scratch stays hidden beside the database folders"
    end
  end
end
