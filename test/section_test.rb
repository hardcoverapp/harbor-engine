require "test_helper"

# The section Harbor draws: a side nav beside the page, on Harbor's own pages
# and on the host's pages that ask for it, and tabs for a page's sub-pages.
class HarborSectionTest < ActionDispatch::IntegrationTest
  include HarborTestConfig

  setup { post "/login", params: { name: "Sam Settings" } }

  test "a page of the section gets the side nav beside it: grouped, with icons, collapsible" do
    get "/reports"
    assert_response :success
    assert_select "main.harbor-shell > aside.harbor-aside > nav.harbor-nav[data-controller='harbor--side-nav']", count: 1
    assert_select "main.harbor-shell > div.harbor-page h1", text: "Reports"
    groups = css_select("[data-harbor-nav] [data-nav-group]").map { |group| [ group["data-nav-group"], group.css("a").map { |a| a.text.strip } ] }
    assert_equal [ [ "flows", %w[Automations Reports] ], [ "activity", %w[Runs] ], [ "settings", %w[Settings] ] ], groups
    assert_select "[data-harbor-nav] .harbor-nav-heading", count: 2
    assert_select "[data-harbor-nav] a.harbor-nav-item svg.harbor-icon[aria-hidden=true]", count: 4
    assert_select "[data-harbor-nav] a.harbor-nav-item[title]", count: 4
    assert_select "[data-harbor-nav] a[aria-current=page]", text: "Reports", count: 1
    assert_select "[data-harbor-nav] button[data-action='harbor--side-nav#toggle'][aria-expanded=true]", count: 1
  end

  test "a page outside the section has no shell" do
    get "/"
    assert_select "main.harbor-shell", count: 0
    assert_select "[data-harbor-nav]", count: 0
  end

  test "the layout's head applies a remembered collapse before the page is drawn" do
    get "/"
    assert_match(/localStorage\.getItem\("harborNav"\) === "collapsed"/, css_select("head script").map(&:text).join)
  end

  test "a notice shows inside the page column" do
    patch harbor.setting_path("agent_auto_retries"), params: { value: "5" }
    follow_redirect!
    assert_select "main.harbor-shell > div.harbor-page > [data-notice]", text: /Saved/
  end

  test "page tabs mark the current one" do
    html = ApplicationController.render(partial: "harbor/shared/page_tabs",
                                        locals: { label: "Workflows", tabs: [ [ "Workflows", "/workflows", true ], [ "Recent runs", "/workflow_runs", false ] ] })
    page = Nokogiri::HTML.fragment(html)
    assert_equal "Workflows", page.at_css("nav.harbor-tabs")["aria-label"]
    assert_equal [ "Workflows" ], page.css("a.harbor-tab[aria-current=page]").map(&:text)
    assert_equal [ "/workflows", "/workflow_runs" ], page.css("a.harbor-tab").map { |a| a["href"] }
  end

  test "the stylesheet defines every theme variable it uses, and colours only there" do
    css = Harbor::Engine.root.join("app/assets/tailwind/harbor/engine.css").read
    defined = css[/:root \{(.*?)\n\}/m, 1].scan(/(--harbor-nav-[\w-]+):/).flatten
    used = css.scan(/var\((--harbor-nav-[\w-]+)\)/).flatten.uniq
    assert_empty used - defined, "used but not defined"
    assert_empty defined - used, "defined but not used"
    rules = css.sub(/:root \{.*?\n\}/m, "").gsub(%r{/\*.*?\*/}m, "")
    assert_no_match(/#[0-9A-Fa-f]{3,6}\b/, rules, "a colour is written outside the theme block")
  end

  test "Harbor's Stimulus controllers are where the import map pins them" do
    pins = Harbor::Engine.root.join("config/importmap.rb").read
    assert_includes pins, 'under: "controllers/harbor"'
    %w[side_nav log_follow].each do |name|
      assert Harbor::Engine.root.join("app/javascript/harbor/controllers/#{name}_controller.js").file?
    end
  end
end
