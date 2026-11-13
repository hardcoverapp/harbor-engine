module Harbor
  module DbOps
    # Back up each database with Greenmask: a `full` dump, and a masked one for
    # each kind the host has rules for. Each lands in the backup folder as
    # <database>/<kind>/<dump id>/, is cataloged, copied to that kind's bucket
    # when one is configured, then retention runs on both.
    class Backup
      def initialize(run:, logger:, directory:)
        @run, @logger, @directory = run, logger, directory
      end

      def call(databases: Database.all.select(&:configured?), variant: nil)
        raise Database::Error, "No source databases configured" if databases.empty?
        store = LocalStore.new
        failures = []
        backups = []
        plan = databases.flat_map do |database|
          variants = variant ? [ variant ] : database.variants
          raise Database::Error, "Unknown backup variant" if (variants - Database::VARIANTS).any?
          variants.map { |kind| [ database, kind ] }
        end
        plan.each.with_index(1) do |(database, kind), step|
          backups << create(database, kind, store, step:, steps: plan.size)
        rescue StandardError => e
          failures << "#{database.name} #{kind}: #{Target.scrub(e.message)}"
          @logger&.call("[backup] ERROR: #{failures.last}")
        end
        raise Pg::Error, failures.join("; ") if failures.any?
        { backups: backups.map(&:id), databases: databases.map(&:key), paths: backups.map(&:path), root: store.root }
      ensure
        @run&.update_columns(progress: {}) if @run&.persisted?
      end

      private

      def create(database, variant, store, step: 1, steps: 1)
        Workspace.assert_space!(@directory)
        target = database.source
        if database.mysql?
          raise Database::Error, "#{database.name} is MySQL, which gets full backups only" unless variant == "full"
          @logger&.call("[backup] #{database.name}: MySQL server #{Mysql.server_version(target, logger: @logger)}")
        else
          Pg.assert_client_new_enough!(Pg.server_version_major(target, logger: @logger))
        end
        rules = Database::MASKED.include?(variant) ? Greenmask.rules(database.key, variant) : nil
        bucket = BackupBucket.for(variant)
        database.assert_fresh!(logger: @logger)
        @logger&.call("[backup] #{database.name} · #{variant}")
        storage = store.absolute(File.join(database.key, variant))
        progress = progress_for(database, variant, target, step:, steps:)
        id = if database.mysql?
          dump_mysql(database, target, storage, progress)
        else
          Greenmask.dump(target, storage_dir: storage, tmp_dir: @directory, rules:, logger: @logger, progress:,
                         jobs: Harbor::Setting.get(:database_backup_jobs))
        end
        relative = File.join(database.key, variant, id)
        dir = store.absolute(relative)
        backup = Harbor::DatabaseBackup.create!(database_key: database.key, variant:, path: relative, run: @run,
                                        bytes: LocalStore.size(dir), sha256: LocalStore.digest(dir),
                                        copies: { Harbor::DatabaseBackup::LOCAL => { "path" => relative, "at" => Time.current.iso8601 } })
        @logger&.call("[backup] saved #{relative} (#{ActiveSupport::NumberHelper.number_to_human_size(backup.bytes)})")
        if bucket
          uploading = BackupProgress.new(run: @run, label: "#{database.name} · #{variant} → #{bucket.bucket}", step:, steps:,
                                         expected_bytes: backup.bytes, logger: @logger)
          bucket.upload_dump(dir, prefix: relative, logger: @logger, progress: uploading)
          backup.record_copy!(bucket.location, bucket: bucket.bucket, key: relative)
        end
        prune(store, database, variant, bucket)
        backup
      end

      # mysqldump into a scratch folder named like a Greenmask dump id, then move
      # the finished folder into place, so a dump folder that exists is complete.
      def dump_mysql(database, target, storage, progress)
        id = (Time.current.to_f * 1000).to_i.to_s
        staged = File.join(@directory, id)
        watcher = Greenmask.watch(@directory, [], progress, @logger) if progress
        begin
          path = Mysql.dump(target, dir: staged, database_key: database.key, logger: @logger)
        ensure
          watcher&.kill
        end
        File.write(File.join(staged, "manifest.json"),
                   JSON.pretty_generate({ database: database.key, engine: "mysql", variant: "full", file: File.basename(path),
                                          bytes: File.size(path), run_id: @run.id, created_at: Time.current.utc.iso8601 }))
        FileUtils.mkdir_p(storage)
        File.rename(staged, File.join(storage, id))
        id
      ensure
        FileUtils.rm_rf(staged) if staged && File.exist?(staged)
      end

      # Estimate from the last backup of the same database and kind; without
      # one, report the source's uncompressed table size for scale.
      def progress_for(database, variant, target, step:, steps:)
        previous = Harbor::DatabaseBackup.where(database_key: database.key, variant:).recent.first
        reference = (database.mysql? ? Mysql.table_data_bytes(target, logger: @logger) : Pg.table_data_bytes(target, logger: @logger)) unless previous
        BackupProgress.new(run: @run, label: "#{database.name} · #{variant}", step:, steps:, logger: @logger,
                           expected_bytes: previous&.bytes, reference_bytes: reference)
      end

      def prune(store, database, variant, bucket)
        keep = Harbor::Setting.get(:database_backups_kept)
        prefix = File.join(database.key, variant)
        if database.mysql?
          LocalStore.prune_dumps(store.absolute(prefix), keep:, logger: @logger)
        else
          Greenmask.prune(storage: Greenmask.directory_storage(store.absolute(prefix)), tmp_dir: @directory, keep:, logger: @logger)
        end
        kind = Harbor::DatabaseBackup.where(database_key: database.key, variant:)
        kind.reject(&:on_disk?).each { |backup| backup.forget_copy!(Harbor::DatabaseBackup::LOCAL) }
        return unless bucket
        stale = bucket.prune(prefix, keep:, logger: @logger)
        kind.reload.select { |backup| stale.include?(backup.dump_id) && backup.copies.key?(bucket.location) }
            .each { |backup| backup.forget_copy!(bucket.location) }
      rescue StandardError => e
        @logger&.call("[backup] retention warning: #{Target.scrub(e.message)}")
      end
    end
  end
end
