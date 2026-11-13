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

    OPERATIONS = %w[db-backup database-restore].freeze

    def index
      # Three tabs: the databases and their backups, the environments they are
      # restored to, and the operations that ran.
      @tab = %w[environments operations].include?(params[:tab]) ? params[:tab].to_sym : :databases
      @operations_available = Harbor.config.database_operation.present?
      @configuration_errors = []
      @environments = configuration_value([]) { DbOps::Environment.all }
      operations = OPERATIONS + @environments.map(&:operation)
      @operation_running = Harbor.run_class.where(loader: operations, status: %w[queued running]).exists?
      return @runs = Harbor.run_class.where(loader: operations).recent.limit(40) if @tab == :operations

      @databases = configuration_value([]) { DbOps::Database.all }
      @restore_next = @environments.index_with { |environment| next_run(environment.operation) }
      return environments_tab if @tab == :environments

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
      # database key => where the file restores it.
      @restores = @environments.flat_map(&:restores).group_by { |entry| entry.database.key }
      @backup_next = next_run("db-backup")
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

    # One chosen backup into one environment. The only things read from the
    # request are which environment, database and backup: the target, the kind
    # allowed and whether the environment is on all come from the config file.
    def restore
      database = DbOps::Database.find!(params[:id])
      environment = DbOps::Environment.find!(params[:environment])
      entry = environment.restore_of!(database.key)
      backup = Harbor::DatabaseBackup.find(params[:backup_id])
      entry.assert_backup!(backup)
      entry.validate!
      raise DbOps::Database::Error, "Type #{database.key} to confirm replacing #{environment.key}" unless params[:confirmation] == database.key
      raise DbOps::LocalStore::Error, "Backup #{backup.path} is missing from disk" unless backup.on_disk?
      start("database-restore", environment: environment.key, database: database.key, backup_id: backup.id)
    end

    # Every database of one environment, from its newest backups. Every entry
    # with a target is checked here; the job checks them all again.
    def restore_environment
      environment = DbOps::Environment.find!(params[:environment])
      environment.assert_enabled!
      environment.restores.select(&:configured?).each(&:validate!)
      start(environment.operation, environment: environment.key)
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

      def environments_tab
        # environment key => its newest restore run, whole or of one database.
        @last_restore = @environments.index_with do |environment|
          Harbor.run_class.where(loader: environment.operation)
                .or(Harbor.run_class.where(loader: "database-restore").where("input ->> 'environment' = ?", environment.key))
                .recent.first
        end
      end

      def next_run(operation) = Harbor.config.database_schedule&.call(operation)

      def configuration_value(fallback)
        yield
      rescue DbOps::Database::Error => error
        @configuration_errors |= [ error.message ]
        fallback
      end

      def configuration_error(error)
        redirect_to databases_path, alert: DbOps::Target.scrub(error.message)
      end
  end
end
