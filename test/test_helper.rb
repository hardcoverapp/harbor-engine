ENV["RAILS_ENV"] = "test"

require_relative "dummy/config/environment"
require "rails/test_help"
require "redis-client"

# Capacity slots are kept in Redis. A host gives Harbor its own connection;
# the tests use REDIS_URL, in a namespace of their own.
HARBOR_TEST_REDIS = RedisClient.config(url: ENV.fetch("REDIS_URL", "redis://127.0.0.1:6379/0")).new_pool(size: 2)
Harbor.config.redis = ->(&block) { HARBOR_TEST_REDIS.with(&block) }
Harbor.config.slot_key = ->(line) { "harbor:test:slots:#{line}" }

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
