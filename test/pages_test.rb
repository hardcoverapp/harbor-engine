require "test_helper"

# Pages a site can switch off: out of the menu, and not found.
class HarborPagesTest < ActionDispatch::IntegrationTest
  include HarborTestConfig

  setup { post "/login", params: { name: "Sam Settings" } }

  def menu = css_select("[data-harbor-menu] a").map { |a| a.text.strip }

  test "every page of the menu has a switch, on by default, except Settings" do
    keys = Harbor.nav.items.filter_map(&:key)
    assert_equal Harbor.nav.items.size - 1, keys.size
    keys.each do |key|
      definition = Harbor::Settings.find("page_#{key}")
      assert_equal [ Harbor::Pages::GROUP, :boolean, true ], [ definition.group, definition.type, definition.default ]
    end
    assert_nil Harbor.nav.items.find { |item| item.label == "Settings" }.key
    assert Harbor::Pages.enabled?(:velocity)
  end

  test "the Settings page lists the switches under Pages" do
    get harbor.settings_path
    assert_select "h2", text: "Pages"
    assert_select "[data-setting='page_velocity'] h3", text: "Velocity"
    assert_select "[data-setting='page_reports'] h3", text: "Reports"
    assert_select "[data-setting='page_velocity'] [data-value]", text: /On/
  end

  test "a page switched off leaves the menu and is not found; switched on, it is back" do
    get "/automations"
    assert_response :success
    assert_includes menu, "Automations"

    patch harbor.setting_path("page_automations"), params: { value: "false" }
    assert_not Harbor::Pages.enabled?(:automations)

    get "/automations"
    assert_response :not_found
    get "/reports"
    assert_response :success
    assert_not_includes menu, "Automations"
    assert_includes menu, "Reports"

    patch harbor.setting_path("page_automations"), params: { value: "true" }
    get "/automations"
    assert_response :success
    assert_includes menu, "Automations"
  end

  test "a page the host added with a key is switched off the same way" do
    Harbor::Setting.set!(:page_reports, "false")
    get "/reports"
    assert_response :not_found
    get "/"
    assert_not_includes menu, "Reports"
  end

  test "reset puts a page back on" do
    Harbor::Setting.set!(:page_automations, "false")
    delete harbor.setting_path("page_automations")
    assert Harbor::Pages.enabled?(:automations)
  end

  test "someone logged out is sent to log in, whether or not the page is on" do
    Harbor::Setting.set!(:page_automations, "false")
    delete "/logout"
    get "/automations"
    assert_redirected_to "/login"
  end

  test "a page with no switch is always on" do
    assert Harbor::Pages.enabled?(:no_such_page)
    assert_equal [], Harbor::Pages.switched_off(%i[no_such_page])
  end

  test "the menu reads its switches with one query" do
    Harbor::Setting.set!(:page_velocity, "false")
    queries = []
    counter = ->(*, payload) { queries << payload[:sql] if payload[:sql].include?("harbor_settings") }
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") do
      assert_equal %i[velocity], Harbor::Pages.switched_off(Harbor.nav.items.filter_map(&:key))
    end
    assert_equal 1, queries.size
  end

  test "adding a page with a key twice, as a reloaded initializer would, declares one switch" do
    Harbor::Pages.declare(:reports, label: "Reports")
    assert_equal 1, Harbor::Settings.all.count { |definition| definition.key == "page_reports" }
  end
end
