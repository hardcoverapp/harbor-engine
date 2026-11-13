module Harbor
  # Replace one database of one restore environment with one saved backup,
  # chosen on the Databases page. The run's input names all three; a run that
  # names no environment is refused, never pointed at a default.
  class DatabaseRestoreJob < DbOperationJob
    self.loader_slug = "database-restore"

    def operate(directory:, logger:)
      input = @operation_run.input
      environment = DbOps::Environment.find!(input["environment"])
      raise self.class::Skipped, environment.off_message unless environment.enabled?
      database = DbOps::Database.find!(input.fetch("database"))
      entry = environment.restore_of!(database.key)
      backup = Harbor::DatabaseBackup.find(input.fetch("backup_id"))
      restore = DbOps::Restore.new(logger:)
      target = restore.preflight(entry, backup)
      path = restore.verify(backup)
      restore.apply(entry, backup, path, target:)
    end
  end
end
