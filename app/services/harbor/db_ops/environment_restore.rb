module Harbor
  module DbOps
    # Restore every database of one environment from its newest backup of the
    # entry's kind. Every entry is checked, then every dump is verified, and
    # only then is the first target replaced: one bad entry or archive leaves
    # every database of the environment untouched.
    #
    # An entry whose target ENV key is unset has nowhere to go. It is left out,
    # and said so in the log; it is never pointed at anything else.
    class EnvironmentRestore
      Error = Harbor::Databases::Error

      def initialize(environment, logger:)
        @environment = environment
        @logger = logger
      end

      # The entries that have a target.
      def entries
        @environment.restores.select do |entry|
          next true if entry.configured?
          @logger&.call("[restore] #{entry.database.name}: #{entry.target_env} is not set, so it is not restored")
          false
        end
      end

      def call(entries = self.entries)
        @environment.assert_enabled!
        max_age = Harbor::Setting.get(:database_max_backup_age_days).days
        restore = Restore.new(logger: @logger)
        plan = entries.map do |entry|
          database = entry.database
          kind = entry.kind
          backup = Harbor::DatabaseBackup.where(database_key: database.key, variant: kind).recent.find(&:on_disk?)
          raise Error, "No #{kind} backup for #{database.name}" unless backup
          if backup.created_at < max_age.ago
            raise Error, "#{database.name}'s newest #{kind} backup is from #{backup.created_at.to_date}; refusing to restore stale data"
          end
          { entry:, backup:, target: restore.preflight(entry, backup) }
        end
        plan.each { |step| step[:path] = restore.verify(step[:backup]) }
        restored = plan.map do |step|
          restore.apply(step[:entry], step[:backup], step[:path], target: step[:target])
        end
        { restored: }
      end
    end
  end
end
