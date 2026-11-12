ENV["RAILS_ENV"] = "test"

require_relative "dummy/config/environment"
require "rails/test_help"

module HarborTestConfig
  # Harbor.config is process-wide; put back what a test changed.
  def self.included(base)
    base.setup do
      @harbor_export = Harbor.config.export
      @harbor_fallbacks = Harbor.config.env_fallbacks.dup
      Harbor.config.export = nil
      Harbor.config.env_fallbacks.clear
      Harbor::Setting.delete_all
    end
    base.teardown do
      Harbor.config.export = @harbor_export
      Harbor.config.env_fallbacks.replace(@harbor_fallbacks)
    end
  end
end
