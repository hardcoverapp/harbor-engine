module Harbor
  # A backup or a restore, as a tracked run (`config.tracked_job`). One runs at
  # a time: each holds the backup folder's lock and gets a scratch folder
  # there. A subclass implements `operate(directory:, logger:)`.
  class DbOperationJob < Harbor.config.tracked_job.constantize
    def perform(run_id)
      @operation_run = Harbor.run_class.find(run_id)
      # A finished run is never replayed, whatever the queue redelivers.
      return if @operation_run.finished?
      super
    end

    def load(logger:)
      DbOps::Workspace.with_lock do |directory|
        operate(directory:, logger:)
      end
    end
  end
end
