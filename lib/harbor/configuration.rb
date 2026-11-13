module Harbor
  # What the host supplies in Ruby. Kept deliberately small: a value that can be
  # a setting edited in the app is not configured here.
  class Configuration
    # The section's menu. The host adds its own pages with `nav.add`.
    attr_reader :nav

    # The controller Harbor's pages inherit from, by name. It brings the host's
    # login check, layout and `current_user`.
    attr_accessor :parent_controller

    # How to name the person who made a change (shown beside it): called with
    # the host's current user.
    attr_accessor :user_label

    # Called with (relative path, text) whenever Harbor saves configuration
    # worth keeping outside the database. nil: nothing is exported.
    attr_accessor :export

    # ENV keys that settings used to be read from, by setting key. The ENV
    # value applies until a value is saved on the Settings page.
    attr_reader :env_fallbacks

    # The class Harbor builds and finds runs with, by name: Harbor's own, or a
    # host's subclass of it that adds what is the host's.
    attr_accessor :run_class

    # The class Harbor finds webhook deliveries with, by name: Harbor's own or
    # a host's subclass of it.
    attr_accessor :webhook_event_class

    # The class Harbor finds model aliases with, by name: Harbor's own or a
    # host's subclass of it.
    attr_accessor :model_alias_class

    # The class Harbor finds agents with, by name: Harbor's own or a host's
    # subclass of it.
    attr_accessor :agent_class

    # The classes Harbor finds runtimes and workspaces with, by name.
    attr_accessor :runtime_class, :workspace_profile_class

    # How Harbor reaches Redis, for capacity slots: called with a block, yields
    # a connection answering `call("COMMAND", …)`. Sidekiq's by default.
    attr_accessor :redis

    # The Redis key of a capacity line's ledger, from the line's name
    # ("runtime:laptop", an agent's key).
    attr_accessor :slot_key

    # Called with a run about to be placed; returns a
    # Harbor::Runtimes::Placement::Hold when a runtime already holds the
    # workspace that run should use, else nil. nil: nothing is sticky.
    attr_accessor :sticky_runtime

    # Called with (run, exit_status:) when a runner reports that a run's
    # command has ended. nil: Harbor finishes the run as ok or error itself.
    attr_accessor :run_reported

    # Called with nothing when where or on what work can run has changed: a
    # runtime switched on or off, a limit raised, a workspace reordered. A host
    # with work waiting for availability looks again. nil: nothing happens.
    attr_accessor :availability_changed

    # Called with the current user when someone asks for model usage to be
    # read again; returns the run doing it. nil: the page offers no refresh.
    attr_accessor :refresh_model_usage

    # A model id as a person reads it ("claude-sonnet-5-5" → "Sonnet 5.5").
    attr_accessor :model_name

    # Where runs' live logs are kept. `log_location` turns a log's relative
    # path into a file path; `log_path` gives a run its relative path (nil for
    # a run with nothing to name its log by).
    attr_accessor :log_location, :log_path

    # The Orca command line Harbor runs agents through: a name on the PATH or
    # a full path.
    attr_accessor :orca_bin

    # The host's Harbor config file (Harbor::ConfigFile): which databases are
    # backed up and which environments they are restored to. A path or a
    # callable returning one; `config/harbor.yml` in the app by default.
    attr_accessor :config_file

    # --- Databases (backups and restores; see README "Databases") ---
    #
    # Where dumps go and what gets run are decided on the machine, not on the
    # Settings page. Each of these may be a value or a callable, which is read
    # every time it is needed. Which databases a restore may replace is not
    # here at all: that is the config file's, and only the config file's.

    # The folder backups are written under, one folder per database and kind.
    attr_accessor :backup_root

    # The same folder as the person at the machine knows it, when the app sees
    # it through a mount. Shown on the page instead of `backup_root`.
    attr_accessor :backup_host_root

    # The folder holding the masking rules: <database>.yml for cleaned
    # backups, staging/<database>.yml for staging ones.
    attr_accessor :masking_rules_path

    # The Greenmask command, and the folder holding the pg_dump and pg_restore
    # it runs (nil: the folder `pg_dump` is found in on the PATH).
    attr_accessor :greenmask_bin, :greenmask_pg_bin_path

    # The prefix of the ENV keys describing the bucket backups are copied to:
    # <prefix>_ENDPOINT, _REGION, _ACCESS_KEY_ID, _SECRET_ACCESS_KEY,
    # _LOCATION, _CLEANED_BUCKET and _FULL_BUCKET.
    attr_accessor :backup_bucket_env_prefix

    # The database role made read-only while a database is replaced (nil: the
    # role in the target's URL).
    attr_accessor :staging_lock_role

    # The application name restores connect with, and the names of other
    # applications whose connections a restore leaves alone.
    attr_accessor :restore_application_name, :restore_spared_applications

    # What each kind of backup is for at this site, by kind ("full", "cleaned",
    # "staging"), where Harbor's own wording doesn't fit.
    attr_accessor :backup_kind_notes

    # The job class database operations inherit from, by name: one whose
    # `perform(run_id)` calls `load(logger:)`, records the result on the run,
    # and records a raised `Skipped` (a constant of the class) as skipped.
    attr_accessor :tracked_job

    # Called with (operation, user:, input:) when someone starts a database
    # operation from the page; starts it and returns its run. The operation
    # is "db-backup", "database-restore" (input: environment, database,
    # backup_id) or an environment's own, "<environment key>-restore" (input:
    # environment). nil: the page starts nothing.
    attr_accessor :database_operation

    # Called with an operation's name; returns when it next runs on a schedule,
    # or nil. nil: the page says nothing is scheduled.
    attr_accessor :database_schedule

    def initialize
      @nav = Nav.new
      @parent_controller = "ApplicationController"
      @user_label = ->(user) { user.try(:name).presence || user.try(:email) }
      @env_fallbacks = {}
      @run_class = "Harbor::Run"
      @webhook_event_class = "Harbor::WebhookEvent"
      @model_alias_class = "Harbor::ModelAlias"
      @agent_class = "Harbor::Agent"
      @runtime_class = "Harbor::Runtime"
      @workspace_profile_class = "Harbor::WorkspaceProfile"
      @redis = lambda do |&block|
        raise "Harbor needs Redis for capacity slots: set config.redis, or load Sidekiq." unless defined?(::Sidekiq)
        ::Sidekiq.redis(&block)
      end
      @slot_key = ->(line) { "harbor:slots:#{line}" }
      @sticky_runtime = nil
      @run_reported = nil
      @availability_changed = nil
      @refresh_model_usage = nil
      @model_name = ->(model) { model }
      @log_location = ->(path) { Rails.root.join("storage/harbor/logs", path) }
      @log_path = lambda do |run|
        name = run.loader.presence || run.skill.presence&.tr(".", "-")
        "#{name}/run-#{run.id}#{run.log_attempt_suffix}.log" if name
      end
      @orca_bin = "orca"
      @config_file = -> { Rails.root.join("config/harbor.yml") }
      @backup_root = -> { Rails.root.join("storage/harbor/backups").to_s }
      @backup_host_root = nil
      @masking_rules_path = -> { Rails.root.join("config/greenmask") }
      @greenmask_bin = "greenmask"
      @greenmask_pg_bin_path = nil
      @backup_bucket_env_prefix = "HARBOR_BACKUP_S3"
      @staging_lock_role = nil
      @restore_application_name = "harbor-restorer"
      @restore_spared_applications = []
      @backup_kind_notes = {}
      @tracked_job = "Harbor::TrackedJob"
      @database_operation = nil
      @database_schedule = nil
    end

    def env_fallback(setting, env_key)
      Settings.find(setting)
      @env_fallbacks[setting.to_s] = env_key.to_s
    end
  end
end
