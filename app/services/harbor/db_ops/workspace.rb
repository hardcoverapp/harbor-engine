require "open3"
require "tmpdir"

module Harbor
  module DbOps
    # One database operation at a time: a lock file in the backup folder, and
    # a scratch folder beside the dumps for the operation holding it.
    module Workspace
      module_function

      # Another operation holding the lock is expected, not a failure: it is
      # raised as the tracked job's own Skipped, so the run is recorded as
      # skipped.
      def busy_error = Harbor.config.tracked_job.constantize::Skipped

      def with_lock
        root = LocalStore.root
        FileUtils.mkdir_p(root, mode: 0o700)
        File.open(File.join(root, ".database-operations.lock"), File::RDWR | File::CREAT, 0o600) do |lock|
          unless lock.flock(File::LOCK_EX | File::LOCK_NB)
            raise busy_error, "Another database operation is running; try again after it finishes"
          end
          Dir.mktmpdir(".operation-", root) { |dir| yield dir }
        end
      end

      def assert_space!(dir)
        out, _, status = Open3.capture3("df", "-Pk", dir)
        raise Pg::Error, "Cannot check free backup space" unless status.success?
        free = out.lines.last.split[3].to_i * 1024
        minimum = Harbor::Setting.get(:database_backup_min_free_gb) * 1024**3
        raise Pg::Error, "Not enough backup space (need #{minimum / 1024**3} GB)" if free < minimum
      end
    end
  end
end
