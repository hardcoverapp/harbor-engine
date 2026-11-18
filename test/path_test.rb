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
    Rails.configuration.x.harbor_dummy_no_home = false
    Rails.application.reload_routes! if @redrawn
  end

  # The pages as a site with this config file has them: routes are drawn
  # again under its path, and put back afterwards.
  def with_pages_at(text, home: true)
    with_file(text) do
      Rails.configuration.x.harbor_dummy_no_home = !home
      @redrawn = true
      Rails.application.reload_routes!
      yield
    end
  end

  def page_paths = Harbor::Engine.routes.routes.map { |route| route.path.spec.to_s }.reject { |path| path.start_with?("/harbor/runner/") }

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
    assert_equal 3, runner.size, "the runner's address never moves: firewalls and runners are given it"
    assert pages.any?
    # Overview is the section's own address; every other page is beneath it.
    assert_includes pages, "/factory(.:format)"
    (pages - [ "/factory(.:format)" ]).each { |path| assert path.start_with?("/factory/"), "#{path} is outside /factory" }
    assert_equal "/factory", harbor.overview_path
    assert_equal "/factory/velocity", harbor.velocity_path
    assert_equal "/factory/notes/work", harbor.stage_note_path("work")
  end

  test "the config file's path: moves the pages, and / puts them at the root" do
    with_file("path: /ops\n") { assert_equal "/ops", Harbor.path }
    with_file("path: /tools/agents\n") { assert_equal "/tools/agents", Harbor.path }
    with_file("path: /\n") { assert_equal [ "", true, "/" ], [ Harbor.path, Harbor.at_root?, Harbor.front_path ] }
    with_file("databases: {}\n") { assert_equal [ "/factory", false, "/factory" ], [ Harbor.path, Harbor.at_root?, Harbor.front_path ] }
  end

  test "a path is taken as written, whichever way its slashes were typed" do
    [ "development", "/development", "/development/", "development/" ].each do |written|
      with_file("path: #{written.to_json}\n") { assert_equal "/development", Harbor.path, written.inspect }
    end
  end

  test "what is written is the whole address: nothing is added to it" do
    with_pages_at("path: /development\n") do
      assert_equal "/development", harbor.overview_path
      assert_equal "/development/runs", harbor.runs_path
      assert_equal "/development/settings", harbor.settings_path
      assert_empty page_paths.grep(/factory/), "no page keeps /factory in its address"
      page_paths.each { |path| assert path.start_with?("/development"), "#{path} is outside /development" }

      get "/development"
      assert_response :success
      assert_select "h1", text: "Overview"
      assert_select "[data-harbor-nav] a[aria-current=page]", text: "Overview"
      get "/development/runs"
      assert_response :success
      assert_select "[data-harbor-nav] a[aria-current=page]", text: "Runs"
      [ "/factory", "/factory/runs", "/development/factory", "/development/factory/runs", "/overview" ].each do |gone|
        get gone
        assert_response :not_found, gone
      end
      assert_equal 3, Harbor::Engine.routes.routes.count { |route| route.path.spec.to_s.start_with?("/harbor/runner/") }, "the runner's address never moves"
    end
  end

  test "at / the site's front page is what /factory was, and every page sits at the root" do
    with_pages_at("path: /\n", home: false) do
      assert_equal "/", harbor.overview_path
      assert_equal "/runs", harbor.runs_path
      assert_equal "/settings", harbor.settings_path
      assert_empty page_paths.grep(/factory/)

      get "/"
      assert_response :success
      assert_select "h1", text: "Overview"
      assert_select "[data-harbor-nav] a[aria-current=page]", text: "Overview", count: 1
      assert_select "[data-harbor-nav] a[href='/']", text: "Overview"
      get "/overview"
      assert_response :success
      assert_select "h1", text: "Overview"

      get "/runs"
      assert_response :success
      assert_select "[data-harbor-nav] a[aria-current=page]", text: "Runs", count: 1, message: "at the root, only the page itself is current"
      get "/factory"
      assert_response :not_found
    end
  end

  test "at / a host's own home page stays the host's, and Overview is linked where it can be reached" do
    with_pages_at("path: /\n") do
      get "/"
      assert_response :success
      assert_select "h1", text: "Overview", count: 0, message: "the host's routes come first"
      assert_equal "/overview", Harbor.front_link

      get "/overview"
      assert_response :success
      assert_select "h1", text: "Overview"
      assert_select "[data-harbor-nav] a[href='/overview'][aria-current=page]", text: "Overview"
      get "/settings"
      assert_select "[data-harbor-nav] a[href='/overview']", text: "Overview"
      assert_select "[data-harbor-nav] a[aria-current=page]", text: "Settings", count: 1
    end
  end

  test "a path that isn't one, or a broken file, leaves the pages under /factory" do
    [ "/Factory", "/fac tory", "//x", "/x?y", "/a//b" ].each do |bad|
      with_file("path: #{bad.to_json}\n") { assert_equal "/factory", Harbor.path, bad.inspect }
    end
    with_file("path: [unclosed\n") { assert_equal "/factory", Harbor.path }
    assert_raises(ArgumentError) { Harbor.normalize_path("/Factory") }
  end
end
