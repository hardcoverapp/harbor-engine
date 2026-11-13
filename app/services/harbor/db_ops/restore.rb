module Harbor
  module DbOps
    # Replace one restore entry's target with a saved backup of its database
    # (see RestoreEntry). Which kind of backup is the entry's to say: a full
    # dump holds everyone's real data and is restored only where the config
    # file names `backup: full`. Masking already happened when a masked dump
    # was made (the host's masking rules).
    class Restore
      def initialize(logger:)
        @logger = logger
      end

      def preflight(entry, backup)
        entry.assert_backup!(backup)
        entry.validate!
        target = entry.target
        Pg.assert_client_new_enough!(Pg.server_version_major(target, logger: @logger))
        target
      end

      # Restores read the dump in place from the backup drive. Check it still
      # matches what was cataloged before anything destructive happens.
      def verify(backup)
        path = backup.archive_path
        raise Pg::Error, "Backup #{backup.path} is missing from disk; nothing was modified" unless File.exist?(path)
        @logger&.call("[restore] verifying #{backup.path}")
        unless LocalStore.size(path) == backup.bytes && LocalStore.digest(path) == backup.sha256
          raise Pg::Error, "Backup checksum or size mismatch; nothing was modified"
        end
        path
      end

      def apply(entry, backup, path, target:)
        # Guards are repeated immediately before the destructive step, even when
        # the caller preflighted a whole batch first.
        entry.assert_backup!(backup)
        entry.validate!
        # What is dropped is what the file names now, not what a caller holds.
        unless target.is_a?(Target) && target.url == entry.target.url
          raise Database::Error, "Refusing to restore: the target is not the one #{entry.target_env} names"
        end
        @logger&.call("[restore] Backup ##{backup.id} → #{target.redacted}")
        StagingLock.with_lock(target, logger: @logger) do |restore_target, env|
          Pg.reset_schemas(restore_target, logger: @logger, env:)
          Pg.restore_file(restore_target, path, logger: @logger, env:)
        end
        { database: entry.database.key, backup_id: backup.id, target: target.redacted }
      end
    end
  end
end
