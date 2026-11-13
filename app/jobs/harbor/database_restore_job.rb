module Harbor
  # Replace one database's staging copy with one saved masked backup, chosen
  # on the Databases page. The run's input names both.
  class DatabaseRestoreJob < DbOperationJob
    self.loader_slug = "database-restore"

    def operate(directory:, logger:)
      raise self.class::Skipped, "Staging restores are switched off (Settings, Databases)" unless DbOps::Database.staging_restores_enabled?
      input = @operation_run.input
      database = DbOps::Database.find!(input.fetch("database"))
      backup = Harbor::DatabaseBackup.find(input.fetch("backup_id"))
      restore = DbOps::Restore.new(logger:)
      target = restore.preflight(database, backup)
      path = restore.verify(backup)
      restore.apply(database, backup, path, target:)
    end
  end
end
