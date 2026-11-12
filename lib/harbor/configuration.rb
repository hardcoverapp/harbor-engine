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

    # Where runs' live logs are kept. `log_location` turns a log's relative
    # path into a file path; `log_path` gives a run its relative path (nil for
    # a run with nothing to name its log by).
    attr_accessor :log_location, :log_path

    def initialize
      @nav = Nav.new
      @parent_controller = "ApplicationController"
      @user_label = ->(user) { user.try(:name).presence || user.try(:email) }
      @env_fallbacks = {}
      @run_class = "Harbor::Run"
      @log_location = ->(path) { Rails.root.join("storage/harbor/logs", path) }
      @log_path = lambda do |run|
        name = run.loader.presence || run.skill.presence&.tr(".", "-")
        "#{name}/run-#{run.id}#{run.log_attempt_suffix}.log" if name
      end
    end

    def env_fallback(setting, env_key)
      Settings.find(setting)
      @env_fallbacks[setting.to_s] = env_key.to_s
    end
  end
end
