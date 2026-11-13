require "harbor/version"
require "harbor/icons"
require "harbor/nav"
require "harbor/nav_helper"
require "harbor/status_helper"
require "harbor/pages"
require "harbor/settings"
require "harbor/task_types"
require "harbor/runtimes"
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
