module Harbor
  # Restore every database of one restore environment from its newest backups
  # (DbOps::EnvironmentRestore). The run's input names the environment; a host
  # with a job per environment overrides `environment_key` instead.
  class EnvironmentRestoreJob < DbOperationJob
    self.loader_slug = "environment-restore"

    def operate(directory:, logger:)
      environment = DbOps::Environment.find!(environment_key)
      raise self.class::Skipped, environment.off_message unless environment.enabled?
      restore = DbOps::EnvironmentRestore.new(environment, logger:)
      entries = restore.entries
      raise self.class::Skipped, "No #{environment.key} database URLs configured" if entries.empty?
      restore.call(entries)
    end

    def environment_key = (@operation_run.input || {})["environment"]
  end
end
