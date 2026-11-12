require_relative "boot"

require "rails"
require "active_model/railtie"
require "active_record/railtie"
require "action_controller/railtie"
require "action_view/railtie"

Bundler.require(*Rails.groups)
require "harbor"

# The smallest host Harbor can be mounted in: a login, a layout and a page of
# its own. It stands in for a real application in the tests.
module Dummy
  class Application < Rails::Application
    config.root = File.expand_path("..", __dir__)
    config.load_defaults 8.1
    config.eager_load = false
    config.secret_key_base = "dummy-secret-key-base-for-tests-only"
    config.hosts.clear
    config.consider_all_requests_local = true
    config.action_dispatch.show_exceptions = :rescuable
    config.active_support.deprecation = :stderr
    # As a generated app's test environment does: forms post without a token.
    config.action_controller.allow_forgery_protection = !Rails.env.test?
    config.active_record.maintain_test_schema = true
    # One schema: the engine's migrations, dumped here.
    config.paths["db/migrate"] = []
  end
end
