module Harbor
  # The declared databases (Harbor::Databases) with their backups, and the
  # backup and restore runs. Starting an operation is the host's
  # (`config.database_operation`): it owns the jobs' schedule and the runs'
  # attribution. Every guard is checked here before anything is queued, and
  # again by the job before anything is touched.
  class DatabasesController < ApplicationController
    harbor_page :database
    helper Harbor::DatabasesHelper
    before_action :require_operations, except: :index
    rescue_from DbOps::Database::Error, DbOps::Target::Error, DbOps::LocalStore::Error, with: :configuration_error

    OPERATIONS = %w[db-backup database-restore staging-restore].freeze

    def index
      # Two tabs: the databases and their backups, and the operations that ran.
      @tab = params[:tab] == "operations" ? :operations : :databases
      @operations_available = Harbor.config.database_operation.present?
      @operation_running = Harbor.run_class.where(loader: OPERATIONS, status: %w[queued running]).exists?
      return @runs = Harbor.run_class.where(loader: OPERATIONS).recent.limit(40) if @tab == :operations

      @configuration_errors = []
      @databases = configuration_value([]) { DbOps::Database.all }
      @database_variants = @databases.index_with { |database| configuration_value([]) { database.variants } }
      # The folder as the app sees it, or as the person at the machine does
      # when the host says (a mount), so the page names the folder they'd open.
      @backup_root = DbOps::LocalStore.root
      @backup_host_root = Harbor::Databases.setting(:backup_host_root).presence
      # Bucket name => the kinds stored in it (cleaned; full + staging).
      @buckets = DbOps::Database::VARIANTS.filter_map { |kind| (name = DbOps::BackupBucket.bucket_for(kind)) && [ kind, name ] }
                                          .group_by(&:last).transform_values { |pairs| pairs.map(&:first) }
      @bucket_location = DbOps::BackupBucket.location if @buckets.any?
      # database key => kind => backups, newest first.
      @backups = @databases.to_h do |database|
        [ database.key, Harbor::DatabaseBackup.where(database_key: database.key).recent.includes(:run).group_by(&:variant) ]
      end
      # Kind => is a bucket configured for it (so a copy is expected there).
      @bucket_kinds = DbOps::Database::VARIANTS.index_with { |kind| DbOps::BackupBucket.bucket_for(kind).present? }
      @restore_on = DbOps::Database.staging_restores_enabled?
      @backup_next = next_run("db-backup")
      @restore_next = next_run("staging-restore")
    end

    def backup
      database = DbOps::Database.find!(params[:id])
      raise DbOps::Database::Error, "#{database.source_env} is not configured" unless database.configured?
      variant = params[:variant].to_s
      raise DbOps::Database::Error, "Unknown backup variant" unless database.variants.include?(variant)
      start("db-backup", database: database.key, variant:)
    end

    def backup_all
      start("db-backup")
    end

    def restore
      database = DbOps::Database.find!(params[:id])
      backup = Harbor::DatabaseBackup.find(params[:backup_id])
      raise DbOps::Database::Error, "Backup belongs to another database" unless backup.database_key == database.key
      raise DbOps::Database::Error, "Only cleaned or staging backups can be restored to staging" unless backup.masked?
      database.validate_staging!
      raise DbOps::Database::Error, "Type #{database.key} to confirm replacing staging" unless params[:confirmation] == database.key
      raise DbOps::LocalStore::Error, "Backup #{backup.path} is missing from disk" unless backup.on_disk?
      start("database-restore", database: database.key, backup_id: backup.id)
    end

    def refresh_staging
      DbOps::Database.assert_staging_restores_enabled!
      start("staging-restore")
    end

    private
      def require_operations
        head :not_found unless Harbor.config.database_operation
      end

      def start(operation, **input)
        user = respond_to?(:current_user, true) ? send(:current_user) : nil
        run = Harbor.config.database_operation.call(operation, user:, input:)
        redirect_to helpers.harbor_run_path(run) || databases_path(tab: "operations"), notice: "Database operation queued."
      end

      def next_run(operation) = Harbor.config.database_schedule&.call(operation)

      def configuration_value(fallback)
        yield
      rescue DbOps::Database::Error => error
        @configuration_errors << error.message
        fallback
      end

      def configuration_error(error)
        redirect_to databases_path, alert: DbOps::Target.scrub(error.message)
      end
  end
end
