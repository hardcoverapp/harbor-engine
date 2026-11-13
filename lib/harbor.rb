require "harbor/version"
require "harbor/icons"
require "harbor/nav"
require "harbor/nav_helper"
require "harbor/status_helper"
require "harbor/pages"
require "harbor/settings"
require "harbor/task_types"
require "harbor/runtimes"
require "harbor/config_file"
require "harbor/databases"
require "harbor/runner"
require "harbor/configuration"
require "harbor/orca"
require "harbor/engine"

# Harbor runs agent work: workflows whose steps are runs, placed on runtimes
# through workspaces, executed by agents with routed models. It is mounted by a
# host application and must not know which one (see README.md).
module Harbor
  class << self
    def config
      @config ||= Configuration.new
    end

    # Host initializer entry point. Only what is code belongs here; anything
    # that is data is an in-app setting.
    def configure
      yield config
    end

    def nav = config.nav

    DEFAULT_PATH = "/factory".freeze

    # Where Harbor's pages live in the host: every page's address starts with
    # this ("/factory/runtimes"). `path:` in the config file changes it;
    # "/" puts the pages at the root. It is read once, when routes are drawn,
    # so changing it takes a restart.
    #
    # A host that still has pages of the section in its own routes puts them
    # under the same path: `scope Harbor.path do … end`.
    def path
      @path ||= begin
        normalize_path(ConfigFile.value("path"))
      rescue ConfigFile::Error, ArgumentError => error
        # A broken file must not take the app down at boot; the pages stay
        # where they are by default and the Databases page reports the file.
        Rails.logger&.error("[harbor] #{error.message}; pages stay under #{DEFAULT_PATH}")
        DEFAULT_PATH
      end
    end

    # "" for the root, else "/like/this": a leading slash, no trailing one.
    def normalize_path(value)
      return DEFAULT_PATH if value.nil?
      text = value.to_s.strip
      return "" if text == "/"
      unless text.match?(%r{\A(/[a-z0-9][a-z0-9_-]*)+\z})
        raise ArgumentError, "#{ConfigFile.label}: path must look like /factory (lowercase letters, numbers, - and _), or / for the root; got #{value.inspect}"
      end
      text
    end

    # Tests only.
    def reset_path!
      @path = nil
    end

    # The host's Run class (Harbor::Run unless the host named its own).
    def run_class = config.run_class.constantize

    def webhook_event_class = config.webhook_event_class.constantize

    def model_alias_class = config.model_alias_class.constantize

    def agent_class = config.agent_class.constantize

    def runtime_class = config.runtime_class.constantize

    def workspace_profile_class = config.workspace_profile_class.constantize

    # Tell the host that where or on what work can run has changed (a runtime
    # switched on, a workspace reordered), so anything waiting can look again.
    def availability_changed! = config.availability_changed&.call

    # A Redis connection, for the slot ledger: yields something answering
    # `call("COMMAND", …)` (`config.redis`).
    def redis(&block) = config.redis.call(&block)

    # A configured class's name, for an association's `class_name:`. Absolute:
    # Active Record looks a relative name up inside Harbor first, where a
    # host's "Run" would be found as Harbor::Run.
    def class_name_for(setting) = "::#{config.public_send(setting).to_s.delete_prefix('::')}"

    # Tests only: start from the defaults again.
    def reset_config!
      @config = nil
    end
  end
end
