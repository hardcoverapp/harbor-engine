require "test_helper"

# The Settings page, rendered inside a host's layout (test/dummy).
class HarborSettingsPageTest < ActionDispatch::IntegrationTest
  include HarborTestConfig

  setup { post "/login", params: { name: "Sam Settings" } }

  test "it needs a login" do
    delete "/logout"
    get harbor.settings_path
    assert_redirected_to "/login"
    patch harbor.setting_path("workflows_enabled"), params: { value: "true" }
    assert_redirected_to "/login"
    assert_equal 0, Harbor::Setting.count
  end

  test "lists every declared setting inside the host's layout, with the menu" do
    get harbor.settings_path
    assert_response :success
    Harbor::Settings.all.each { |definition| assert_select "[data-setting='#{definition.key}'] h3", text: definition.label }
    assert_select "[data-setting='workflows_enabled'] [data-value]", text: /Off/
    assert_select "[data-setting='workflows_enabled'] [data-source]", text: /Default/
    assert_select "[data-harbor-menu] a.current", text: "Settings"
    assert_select "div.border-b.mb-8 a.font-medium", text: "Settings"
  end

  test "the host's layout links to its own pages by bare route helper on a Harbor page" do
    get harbor.settings_path
    assert_select "[data-host-nav] a[href='/reports']", text: "Reports"
    assert_select "[data-harbor-menu] a[href='/reports']", text: "Reports"
  end

  test "a switch saves at once and says who set it" do
    patch harbor.setting_path("workflows_enabled"), params: { value: "true" }
    assert_redirected_to harbor.settings_path
    assert_equal true, Harbor::Setting.get(:workflows_enabled)
    follow_redirect!
    assert_select "[data-setting='workflows_enabled'] [data-value]", text: /On/
    assert_select "[data-setting='workflows_enabled'] [data-source]", text: /Set here by Sam Settings/
  end

  test "a value from the environment is shown as such until one is saved here" do
    Harbor.config.env_fallback :agent_auto_retries, "HARBOR_TEST_PAGE_RETRIES"
    ENV["HARBOR_TEST_PAGE_RETRIES"] = "6"
    get harbor.settings_path
    assert_select "[data-setting='agent_auto_retries'] input[name=value][value='6']"
    assert_select "[data-setting='agent_auto_retries'] [data-source]", text: /HARBOR_TEST_PAGE_RETRIES/
  ensure
    ENV.delete("HARBOR_TEST_PAGE_RETRIES")
  end

  test "a number saves, a bad one is refused with a message" do
    patch harbor.setting_path("agent_auto_retries"), params: { value: "5" }
    assert_equal 5, Harbor::Setting.get(:agent_auto_retries)

    patch harbor.setting_path("agent_auto_retries"), params: { value: "99" }
    follow_redirect!
    assert_match "at most 10", response.body
    assert_equal 5, Harbor::Setting.get(:agent_auto_retries)
  end

  test "reset forgets the saved value" do
    Harbor::Setting.set!(:agent_auto_retries, "5")
    delete harbor.setting_path("agent_auto_retries")
    assert_redirected_to harbor.settings_path
    assert_equal 3, Harbor::Setting.get(:agent_auto_retries)
  end

  test "an undeclared key is a 404" do
    patch harbor.setting_path("nope"), params: { value: "1" }
    assert_response :not_found
  end
end
