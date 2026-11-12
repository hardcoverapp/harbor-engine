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

    # Where runs' live logs are kept. `log_location` turns a log's relative
    # path into a file path; `log_path` gives a run its relative path (nil for
    # a run with nothing to name its log by).
    attr_accessor :log_location, :log_path

    # The Orca command line Harbor runs agents through: a name on the PATH or
    # a full path.
    attr_accessor :orca_bin

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
      @log_location = ->(path) { Rails.root.join("storage/harbor/logs", path) }
      @log_path = lambda do |run|
        name = run.loader.presence || run.skill.presence&.tr(".", "-")
        "#{name}/run-#{run.id}#{run.log_attempt_suffix}.log" if name
      end
      @orca_bin = "orca"
    end

    def env_fallback(setting, env_key)
      Settings.find(setting)
      @env_fallbacks[setting.to_s] = env_key.to_s
    end
  end
end
