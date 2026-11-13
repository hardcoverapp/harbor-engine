require "test_helper"
require "tempfile"

# Where Harbor's pages live in the host: under /factory, or wherever the
# config file's `path:` says.
class HarborPathTest < ActionDispatch::IntegrationTest
  include HarborTestConfig

  setup do
    @config_file = Harbor.config.config_file
    post "/login", params: { name: "Sam Settings" }
  end

  teardown do
    Harbor.config.config_file = @config_file
    Harbor::ConfigFile.reload!
    Harbor.reset_path!
  end

  def with_file(text)
    file = Tempfile.new([ "harbor", ".yml" ])
    file.write(text)
    file.close
    Harbor.config.config_file = file.path
    Harbor::ConfigFile.reload!
    Harbor.reset_path!
    yield
  ensure
    file.unlink
  end

  test "every page is under /factory by default" do
    assert_equal "/factory", Harbor.path
    assert_equal "/factory/settings", harbor.settings_path
    assert_equal "/factory/runtimes", harbor.runtimes_path
    assert_equal "/factory/workspaces", harbor.workspace_profiles_path
    assert_equal "/factory/models", harbor.models_path
    assert_equal "/factory/databases", harbor.databases_path
    assert_equal "/factory/webhooks", harbor.webhooks_path
    get "/factory/settings"
    assert_response :success
    get "/settings"
    assert_response :not_found
  end

  test "every page route is under the path, and nothing else is but the runner's" do
    paths = Harbor::Engine.routes.routes.map { |route| route.path.spec.to_s }
    runner, pages = paths.partition { |path| path.start_with?("/harbor/runner/") }
    assert_equal 2, runner.size, "the runner's address never moves: firewalls and runners are given it"
    assert pages.any?
    pages.each { |path| assert path.start_with?("/factory/"), "#{path} is outside /factory" }
  end

  test "the config file's path: moves the pages, and / puts them at the root" do
    with_file("path: /ops\n") { assert_equal "/ops", Harbor.path }
    with_file("path: /tools/agents\n") { assert_equal "/tools/agents", Harbor.path }
    with_file("path: /\n") { assert_equal "", Harbor.path }
    with_file("databases: {}\n") { assert_equal "/factory", Harbor.path }
  end

  test "a path that isn't one, or a broken file, leaves the pages under /factory" do
    [ "factory", "/Factory", "/factory/", "/fac tory", "//x", "/x?y", 7 ].each do |bad|
      with_file("path: #{bad.to_json}\n") { assert_equal "/factory", Harbor.path, bad.inspect }
    end
    with_file("path: [unclosed\n") { assert_equal "/factory", Harbor.path }
    assert_raises(ArgumentError) { Harbor.normalize_path("factory") }
  end
end
