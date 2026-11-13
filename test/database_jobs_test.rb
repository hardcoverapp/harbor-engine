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

    failing = Harbor::Run.create!(loader: "database-restore", trigger_source: "manual", input: { "database" => "nowhere", "backup_id" => @backup.id })
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

  private
    def restore_run
      Harbor::Run.create!(loader: "database-restore", trigger_source: "manual", input: { "database" => "ledger", "backup_id" => @backup.id })
    end
end
