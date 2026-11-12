require "test_helper"

# Harbor is mounted at the host's root, last. The host's own pages have to
# work exactly as they would without it.
class HarborHostPagesTest < ActionDispatch::IntegrationTest
  include HarborTestConfig

  setup { post "/login", params: { name: "Sam Settings" } }

  test "a host page renders Harbor's menu, with the page the host added" do
    get "/reports"
    assert_response :success
    labels = css_select("[data-harbor-menu] a").map { |a| a.text.strip }
    assert_equal %w[Automations Reports Runs Webhooks Settings], labels
    assert_select "[data-harbor-menu] a.current", text: "Reports"
    assert_select "[data-harbor-menu] a[href='/settings']", text: "Settings"
  end

  test "a path neither the host nor Harbor knows is a 404" do
    get "/no-such-page"
    assert_response :not_found
  end

  test "every Harbor route needs the host's login" do
    delete "/logout"
    Harbor::Engine.routes.routes.each do |route|
      path = route.path.spec.to_s.sub("(.:format)", "").gsub(/:\w+/, "1")
      process(route.verb.downcase.to_sym, path)
      assert_redirected_to "/login", "#{route.verb} #{path} was served without a login"
    end
  end
end
