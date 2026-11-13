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

  test "preflight refuses another database's backup, full backups and disabled staging" do
    database = Harbor::DbOps::Database.find!("time")
    @backup.update!(database_key: "shop")
    assert_raises(Harbor::DbOps::Database::Error) { @restore.preflight(database, @backup) }
    @backup.update!(database_key: "time", variant: "full")
    error = assert_raises(Harbor::DbOps::Database::Error) { @restore.preflight(database, @backup) }
    assert_match "Only cleaned or staging", error.message
    @backup.update!(variant: "staging")
    target = with_stub(Harbor::DbOps::Pg, :server_version_major, 16) { with_stub(Harbor::DbOps::Pg, :assert_client_new_enough!, true) { @restore.preflight(database, @backup) } }
    assert target.same_server_and_db?(database.staging), "staging backups restore to staging"
    @backup.update!(variant: "cleaned")
    Harbor::Setting.set!(:database_staging_restores, "false")
    assert_raises(Harbor::DbOps::Database::Error) { @restore.preflight(database, @backup) }
  end

  test "apply wipes staging and restores the dump under the staging lock" do
    database = Harbor::DbOps::Database.find!("time")
    calls = []
    lock = ->(target, **, &block) { calls << :lock; block.call(target, {}) }
    with_stub(Harbor::DbOps::StagingLock, :with_lock, lock) do
      with_stub(Harbor::DbOps::Pg, :reset_schemas, ->(*, **) { calls << :reset }) do
        with_stub(Harbor::DbOps::Pg, :restore_file, ->(_target, path, **) { calls << [ :restore, path ] }) do
          @restore.apply(database, @backup, @backup.folder, target: database.staging)
          @backup.update!(variant: "full")
          assert_raises(Harbor::DbOps::Database::Error) { @restore.apply(database, @backup, @backup.folder, target: database.staging) }
          # The guards run again right before the destructive step.
          @backup.update!(variant: "cleaned")
          Harbor::Setting.set!(:database_staging_restores, "false")
          assert_raises(Harbor::DbOps::Database::Error) { @restore.apply(database, @backup, @backup.folder, target: database.staging) }
          enable_staging_restores!
          ENV["TIME_STAGING_DB_URL"] = ENV["TIME_DB_URL"]
          assert_raises(Harbor::DbOps::Target::Error) { @restore.apply(database, @backup, @backup.folder, target: database.staging) }
        end
      end
    end
    assert_equal [ :lock, :reset, [ :restore, @backup.folder ] ], calls
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
