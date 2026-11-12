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

    def initialize
      @nav = Nav.new
      @parent_controller = "ApplicationController"
      @user_label = ->(user) { user.try(:name).presence || user.try(:email) }
      @env_fallbacks = {}
    end

    def env_fallback(setting, env_key)
      Settings.find(setting)
      @env_fallbacks[setting.to_s] = env_key.to_s
    end
  end
end
