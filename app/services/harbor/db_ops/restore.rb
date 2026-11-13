module Harbor
  module DbOps
    # Replace a staging database with a saved masked dump: the `staging` kind
    # (made with the staging rules) or `cleaned`. Full dumps hold
    # everyone's real data and are never restored to staging; masking already
    # happened when the dump was made (the host's masking rules).
    class Restore
      def initialize(logger:)
        @logger = logger
      end

      def preflight(database, backup)
        raise Database::Error, "Backup belongs to another database" unless backup.database_key == database.key
        raise Database::Error, "Only cleaned or staging backups can be restored to staging" unless backup.masked?
        database.validate_staging!
        target = database.staging
        Pg.assert_client_new_enough!(Pg.server_version_major(target, logger: @logger))
        target
      end

      # Restores read the dump in place from the backup drive. Check it still
      # matches what was cataloged before anything destructive happens.
      def verify(backup)
        path = backup.archive_path
        raise Pg::Error, "Backup #{backup.path} is missing from disk; staging was not modified" unless File.exist?(path)
        @logger&.call("[restore] verifying #{backup.path}")
        unless LocalStore.size(path) == backup.bytes && LocalStore.digest(path) == backup.sha256
          raise Pg::Error, "Backup checksum or size mismatch; staging was not modified"
        end
        path
      end

      def apply(database, backup, path, target:)
        # Guards are repeated immediately before the destructive step, even when
        # the caller preflighted a whole batch first.
        raise Database::Error, "Only cleaned or staging backups can be restored to staging" unless backup.masked?
        database.validate_staging!
        @logger&.call("[restore] Backup ##{backup.id} → #{target.redacted}")
        StagingLock.with_lock(target, logger: @logger) do |restore_target, env|
          Pg.reset_schemas(restore_target, logger: @logger, env:)
          Pg.restore_file(restore_target, path, logger: @logger, env:)
        end
        { database: database.key, backup_id: backup.id, target: target.redacted }
      end
    end
  end
end
