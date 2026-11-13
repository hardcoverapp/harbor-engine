require "test_helper"
require "tmpdir"

class HarborDbOpsBackupTest < ActiveSupport::TestCase
  include HarborDatabasesConfig

  setup do
    declare_databases "shop_cache", "ledger", "blog"
    ENV["SHOP_CACHE_DB_URL"] = "postgres://backup:secret@follower/cache"
    Harbor::Setting.set!(:database_backup_min_free_gb, "0")
    @root = @backup_root
    @scratch = File.join(@root, ".operation-test")
    FileUtils.mkdir_p(@scratch)
    @run = Harbor::Run.create!(loader: "db-backup", trigger_source: "manual")
    @database = Harbor::DbOps::Database.find!("shop_cache")
    @dumps = []
    @prunes = []
    @progress = []
    @jobs = []
  end

  test "full and cleaned dumps land under <database>/<kind>/<dump id> and are cataloged" do
    with_greenmask { backup.call(databases: [ @database ]) }

    assert_equal [ [ "full", nil ], [ "cleaned", "public.cache_entries" ] ],
                 @dumps.map { |kind, rules| [ kind, rules&.dig("pg_dump_options", "exclude-table-data")&.first ] }
    backups = Harbor::DatabaseBackup.where(run: @run).order(:id)
    assert_equal %w[full cleaned], backups.map(&:variant)
    backups.each do |saved|
      assert_match %r{\Ashop_cache/(full|cleaned)/\d{13}\z}, saved.path
      assert saved.on_disk?
      assert_equal 10, saved.bytes
      assert_equal Harbor::DbOps::LocalStore.digest(saved.folder), saved.sha256
      assert_equal({ "local" => true }, saved.locations)
      assert_equal saved.path, saved.copies.dig("local", "path")
    end
    assert_equal [ [ "shop_cache/full", 4 ], [ "shop_cache/cleaned", 4 ] ], @prunes
    assert_equal [ 2, 2 ], @jobs, "the parallel dump jobs setting reaches every dump"
    assert_equal [ [ "Shop Cache · full", 1, 2 ], [ "Shop Cache · cleaned", 2, 2 ] ],
                 @progress.map { |p| p.snapshot(0).values_at("label", "step", "steps") }
    assert_equal({}, @run.reload.progress, "progress is cleared when the run's backups finish")
  end

  test "progress is estimated from the previous backup of the same database and kind" do
    Harbor::DatabaseBackup.create!(database_key: "shop_cache", variant: "cleaned", path: "shop_cache/cleaned/1600000000000",
                           bytes: 5.gigabytes, sha256: "x")
    with_greenmask { backup.call(databases: [ @database ], variant: "cleaned") }
    assert_equal 5.gigabytes, @progress.first.expected_bytes
  end

  test "a configured bucket receives the dump under the same path" do
    uploads = []
    bucket = Object.new
    pruned = []
    bucket.define_singleton_method(:bucket) { "dev-dumps" }
    bucket.define_singleton_method(:location) { "r2" }
    bucket.define_singleton_method(:upload_dump) { |dir, prefix:, **| uploads << [ File.basename(dir), prefix ] }
    bucket.define_singleton_method(:prune) { |*, **| pruned }
    with_stub(Harbor::DbOps::BackupBucket, :for, ->(kind) { kind == "cleaned" ? bucket : nil }) do
      with_greenmask { backup.call(databases: [ @database ], variant: "cleaned") }
    end
    saved = Harbor::DatabaseBackup.find_by!(run: @run)
    assert_equal [ [ saved.path.split("/").last, saved.path ] ], uploads
    assert_equal({ "local" => true, "r2" => true }, saved.locations)
    assert_equal({ "bucket" => "dev-dumps", "key" => saved.path }, saved.copies["r2"].except("at"))
  end

  test "retention forgets each copy it deletes and drops a backup with none left" do
    gone_everywhere = Harbor::DatabaseBackup.create!(database_key: "shop_cache", variant: "cleaned", path: "shop_cache/cleaned/1600000000001",
                                             bytes: 1, sha256: "x", copies: { "local" => {}, "r2" => {} })
    only_in_bucket = Harbor::DatabaseBackup.create!(database_key: "shop_cache", variant: "cleaned", path: "shop_cache/cleaned/1600000000002",
                                            bytes: 1, sha256: "x", copies: { "local" => {}, "r2" => {} })
    bucket = Object.new
    bucket.define_singleton_method(:bucket) { "dev-dumps" }
    bucket.define_singleton_method(:location) { "r2" }
    bucket.define_singleton_method(:upload_dump) { |*, **| true }
    bucket.define_singleton_method(:prune) { |*, **| [ "1600000000001" ] }
    with_stub(Harbor::DbOps::BackupBucket, :for, ->(kind) { kind == "cleaned" ? bucket : nil }) do
      with_greenmask { backup.call(databases: [ @database ], variant: "cleaned") }
    end
    refute Harbor::DatabaseBackup.exists?(gone_everywhere.id), "deleted from the drive and the bucket"
    assert_equal({ "r2" => {} }, only_in_bucket.reload.copies, "drive copy gone, bucket copy kept")
    assert_equal({ "local" => false, "r2" => true }, only_in_bucket.locations)
  end

  test "MySQL databases are dumped with mysqldump into the same layout and retention" do
    ENV["BLOG_DB_URL"] = "mysql://backup:pw@mysql.example/blog"
    blog = Harbor::DbOps::Database.find!("blog")
    old = File.join(@root, "blog/full/1600000000000")
    FileUtils.mkdir_p(old)
    File.write(File.join(old, "blog.sql.gz"), "old")
    Harbor::Setting.set!(:database_backups_kept, "1")
    dump = ->(_target, dir:, database_key:, **) { FileUtils.mkdir_p(dir); File.join(dir, "#{database_key}.sql.gz").tap { File.write(_1, "dump") } }
    with_stub(Harbor::DbOps::Mysql, :server_version, "8.0.36") do
      with_stub(Harbor::DbOps::Mysql, :table_data_bytes, 1_000) do
        with_stub(Harbor::DbOps::Mysql, :dump, dump) do
          with_greenmask { backup.call(databases: [ blog ]) }
        end
      end
    end
    saved = Harbor::DatabaseBackup.find_by!(run: @run)
    assert_match %r{\Ablog/full/\d{13}\z}, saved.path
    assert saved.on_disk?
    assert_equal %w[blog.sql.gz manifest.json], Dir.children(saved.folder).sort
    assert_equal "mysql", JSON.parse(File.read(File.join(saved.folder, "manifest.json")))["engine"]
    refute File.exist?(old), "MySQL retention keeps the newest dumps, as many as the setting says"
    assert_empty @dumps, "Greenmask is not used for MySQL"
    assert_empty @prunes, "nor is Greenmask's retention"
    assert_empty Dir.children(@scratch)
  end

  test "a failed dump records nothing and reports the failure" do
    failing = ->(*, **) { raise Harbor::DbOps::Pg::Error, "connection refused" }
    with_greenmask(dump: failing) do
      error = assert_raises(Harbor::DbOps::Pg::Error) { backup.call(databases: [ @database ]) }
      assert_match "connection refused", error.message
    end
    assert_empty Harbor::DatabaseBackup.where(run: @run)
  end

  test "cleaned backups need a rules file" do
    ENV["LEDGER_DB_URL"] = "postgres://backup:secret@follower/ledger"
    with_greenmask do
      assert_raises(Harbor::DbOps::Pg::Error) { backup.call(databases: [ Harbor::DbOps::Database.find!("ledger") ], variant: "cleaned") }
    end
    assert_empty @dumps
  end

  test "with no database configured there is nothing to back up" do
    ENV.delete("SHOP_CACHE_DB_URL")
    error = assert_raises(Harbor::DbOps::Database::Error) { with_greenmask { backup.call } }
    assert_match "No source databases configured", error.message
  end

  test "a backup is refused when the backup folder's disk is short of the free space setting" do
    Harbor::Setting.set!(:database_backup_min_free_gb, "100000000")
    with_greenmask do
      error = assert_raises(Harbor::DbOps::Pg::Error) { backup.call(databases: [ @database ], variant: "full") }
      assert_match "Not enough backup space", error.message
    end
    assert_empty @dumps
  end

  test "a source that stopped receiving writes is not backed up" do
    stale = ->(*, **) { raise Harbor::DbOps::Freshness::Error, "looks abandoned" }
    with_greenmask do
      with_stub(@database, :assert_fresh!, stale) do
        error = assert_raises(Harbor::DbOps::Pg::Error) { backup.call(databases: [ @database ], variant: "full") }
        assert_match "looks abandoned", error.message
      end
    end
    assert_empty @dumps
  end

  private

  def backup = Harbor::DbOps::Backup.new(run: @run, logger: nil, directory: @scratch)

  def with_greenmask(dump: nil, &block)
    dumps, prunes, progresses, job_counts = @dumps, @prunes, @progress, @jobs
    dump ||= lambda do |_target, storage_dir:, rules:, progress: nil, jobs: nil, **|
      progresses << progress
      job_counts << jobs
      dumps << [ File.basename(storage_dir), rules ]
      id = (1_700_000_000_000 + dumps.size).to_s
      FileUtils.mkdir_p(File.join(storage_dir, id))
      File.write(File.join(storage_dir, id, "toc.dat"), "toc")
      File.write(File.join(storage_dir, id, "metadata.json"), "{}")
      File.write(File.join(storage_dir, id, "1.dat.gz"), "data!")
      id
    end
    prune = ->(storage:, keep:, **) { prunes << [ storage.dig("directory", "path").delete_prefix("#{@root}/"), keep ] }
    with_stub(Harbor::DbOps::Pg, :server_version_major, 16) do
      with_stub(Harbor::DbOps::Pg, :assert_client_new_enough!, true) do
        with_stub(Harbor::DbOps::Freshness, :assert_fresh!, true) do
          with_stub(Harbor::DbOps::Pg, :table_data_bytes, 40.gigabytes) do
            with_stub(Harbor::DbOps::Greenmask, :dump, dump) do
              with_stub(Harbor::DbOps::Greenmask, :prune, prune, &block)
            end
          end
        end
      end
    end
  end
end
