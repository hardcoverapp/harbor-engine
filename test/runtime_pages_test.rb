require "test_helper"

class HarborRuntimePagesTest < ActionDispatch::IntegrationTest
  include HarborTestConfig

  class PageBackend < Harbor::Runtimes::Backend
    class << self
      attr_accessor :healthy
      def label = "Page test"
    end
    def health_check = self.class.healthy ? true : raise("no answer")
    def warnings = [ "Check the cable." ]
  end

  setup do
    [ Harbor::Agent, Harbor::WorkspaceProfileRuntime, Harbor::WorkspaceProfile, Harbor::Run, Harbor::Runtime ].each(&:delete_all)
    Harbor::Runtimes.register "page", "HarborRuntimePagesTest::PageBackend"
    PageBackend.healthy = true
    HARBOR_TEST_REDIS.with { |r| r.call("KEYS", "harbor:test:slots:*").each { |k| r.call("DEL", k) } }
    @cloud = Harbor::Runtime.create!(key: "cloud", name: "Cloud", backend: "page", max_concurrent: 3, position: 0, host: "cloud.example")
    @laptop = Harbor::Runtime.create!(key: "laptop", name: "Laptop", backend: "page", max_concurrent: 2, position: 1)
    @workspace = Harbor::WorkspaceProfile.create!(name: "Default", description: "Cloud first",
                                                  workspace_profile_runtimes_attributes: [ { runtime: @cloud, position: 0 }, { runtime: @laptop, position: 1 } ])
    @changes = 0
    Harbor.config.availability_changed = -> { @changes += 1 }
    post "/login", params: { name: "Sam Settings" }
  end

  teardown do
    Harbor::Runtimes.unregister "page"
    Harbor.config.availability_changed = nil
  end

  test "the runtimes page shows each runtime's limit, busy count, health and workspaces" do
    Harbor::Runtimes::Slots.acquire(@cloud, "run-1", ttl: 60)
    get harbor.runtimes_path
    assert_response :success
    assert_select "[data-runtime=cloud]" do
      assert_select "h2", "Cloud"
      assert_select "[data-busy]", text: /1 \/ 3/
      assert_select "[data-health]", text: "Taking new work"
      assert_select "p", text: /Page test · cloud.example · cloud/
      assert_select "p", text: "In Default"
      assert_select "p", text: "Check the cable."
      assert_select "form[action=?]", harbor.check_runtime_path(@cloud)
    end
    assert_select "[data-controller='harbor--poll']"
    assert_select "[data-harbor-nav] a[aria-current=page]", text: "Runtimes"
  end

  test "a runtime is switched off, limited and configured from the page" do
    patch harbor.runtime_path(@cloud), params: { runtime: { enabled: false } }
    assert_redirected_to harbor.runtimes_path
    assert_not @cloud.reload.enabled?
    assert_equal 1, @changes, "the host is told availability changed"
    follow_redirect!
    assert_select "[data-runtime=cloud] [data-health]", text: "Not taking new work: disabled"

    patch harbor.runtime_path(@laptop), params: { runtime: { max_concurrent: 7 } }
    assert_equal 7, @laptop.reload.max_concurrent
    patch harbor.runtime_path(@laptop), params: { runtime: { max_concurrent: 0 } }
    assert_equal 7, @laptop.reload.max_concurrent
    assert_match "greater than 0", flash[:alert]

    patch harbor.runtime_path(@laptop), params: { runtime: { config: '{"repo": "name:app"}', name: "Sam's laptop" } }
    assert_equal({ "repo" => "name:app" }, @laptop.reload.config)
    assert_equal "Sam's laptop", @laptop.name
    patch harbor.runtime_path(@laptop), params: { runtime: { config: "[1]" } }
    assert_equal "Config must be a JSON object.", flash[:alert]
    patch harbor.runtime_path(@laptop), params: { runtime: { config: "{not json" } }
    assert flash[:alert].present?
    assert_equal({ "repo" => "name:app" }, @laptop.reload.config)
  end

  test "a runtime is added from the page, with each backend saying what its config means" do
    get harbor.new_runtime_path
    assert_response :success
    assert_select "select[name='runtime[backend]'] option[value=orca]", text: "Orca (orca)"
    assert_select "select[name='runtime[backend]'] option[value=page]"
    assert_select "[data-backend-help]", text: /Orca:.*repo is the Orca repo/m

    assert_difference("Harbor::Runtime.count", 1) do
      post harbor.runtimes_path, params: { runtime: { name: "Sam's laptop", backend: "orca", max_concurrent: 2, enabled: "1",
                                                      config: '{"repo": "name:app", "environment": "sam"}' } }
    end
    assert_redirected_to harbor.runtimes_path
    added = Harbor::Runtime.find_by!(key: "sam-s-laptop")
    assert_equal [ "Sam's laptop", "orca", 2, true, { "repo" => "name:app", "environment" => "sam" } ],
                 [ added.name, added.backend, added.max_concurrent, added.enabled, added.config ]
    assert_operator added.position, :>, @laptop.position, "a new runtime goes last"
    assert_empty added.workspace_profiles, "and takes no work until a workspace lists it"
    assert_equal 0, @changes, "so nothing waiting is told to look again"
  end

  test "a runtime that isn't valid is shown again with what is wrong, and nothing is added" do
    assert_no_difference("Harbor::Runtime.count") do
      post harbor.runtimes_path, params: { runtime: { name: "", backend: "nope", max_concurrent: 0, config: "{}" } }
      assert_response :unprocessable_entity
      assert_select "[role=alert]", text: /Name can't be blank.*not a registered backend.*greater than 0/m

      post harbor.runtimes_path, params: { runtime: { name: "Odd", backend: "page", max_concurrent: 1, config: "{not json" } }
      assert_response :unprocessable_entity
      assert_select "[role=alert]", text: /Config must be valid JSON/
      assert_select "input[name='runtime[name]'][value=Odd]"

      post harbor.runtimes_path, params: { runtime: { name: "List", backend: "page", max_concurrent: 1, config: "[1]" } }
      assert_select "[role=alert]", text: /Config must be a JSON object/

      post harbor.runtimes_path, params: { runtime: { name: "Cloud again", key: "cloud", backend: "page", max_concurrent: 1, config: "{}" } }
      assert_select "[role=alert]", text: /Key has already been taken/
    end
  end

  test "only a runtime nothing depends on can be removed" do
    spare = Harbor::Runtime.create!(key: "spare", name: "Spare", backend: "page")
    get harbor.runtimes_path
    assert_select "[data-runtime=spare] form[action=?] input[name=_method][value=delete]", harbor.runtime_path(spare)
    assert_select "[data-runtime=cloud] input[name=_method][value=delete]", count: 0, message: "a runtime in a workspace offers no Remove"

    delete harbor.runtime_path(@cloud)
    assert_match "Cloud can't be removed", flash[:alert]
    assert Harbor::Runtime.exists?(@cloud.id)

    used = Harbor::Runtime.create!(key: "used", name: "Used", backend: "page")
    Harbor::Run.create!(skill: "writer.fix", status: "ok", runtime_id: used.id)
    delete harbor.runtime_path(used)
    assert_match "Used can't be removed", flash[:alert]

    delete harbor.runtime_path(spare)
    assert_equal "Spare removed.", flash[:notice]
    assert_not Harbor::Runtime.exists?(spare.id)
  end

  test "a health check records its result either way" do
    PageBackend.healthy = false
    post harbor.check_runtime_path(@cloud)
    assert_match "Cloud failed its health check: RuntimeError: no answer", flash[:alert]
    assert_match "unhealthy", @cloud.reload.unavailable_reason
    PageBackend.healthy = true
    post harbor.check_runtime_path(@cloud)
    assert_equal "Cloud is healthy.", flash[:notice]
    assert_nil @cloud.reload.unavailable_reason
  end

  test "the workspaces page lists each workspace's runtimes in order, with who uses it" do
    Harbor::Agent.create!(key: "writer", workspace_profile: @workspace)
    @laptop.update!(enabled: false)
    get harbor.workspace_profiles_path
    assert_response :success
    assert_select "[data-workspace=default]" do
      assert_select "li", count: 2
      assert_select "li:first-child", text: /First\s*Cloud\s*0\/3 busy/
      assert_select "li:last-child", text: /Then 1\s*Laptop.*disabled/mii
      assert_select "p", text: /Agents: writer · key default/
    end
    assert_select "[data-harbor-nav] a[aria-current=page]", text: "Workspaces"
  end

  test "a workspace is created, reordered and deleted" do
    get harbor.new_workspace_profile_path
    assert_response :success
    assert_select "form[data-controller='harbor--nested-fields'] template"
    assert_select "select[name$='[runtime_id]'] option", text: "Laptop"

    post harbor.workspace_profiles_path, params: { workspace_profile: { name: "Overflow", description: "Laptop only",
      workspace_profile_runtimes_attributes: { "0" => { runtime_id: @laptop.id, position: 0 } } } }
    assert_redirected_to harbor.workspace_profiles_path
    overflow = Harbor::WorkspaceProfile.find_by!(key: "overflow")
    assert_equal [ @laptop ], overflow.ordered_runtimes

    post harbor.workspace_profiles_path, params: { workspace_profile: { name: "Empty" } }
    assert_response :unprocessable_entity
    assert_select "[role=alert]", text: /Add at least one runtime/

    get harbor.edit_workspace_profile_path(@workspace)
    assert_select "input[name='workspace_profile[key]'][readonly]"
    rows = @workspace.workspace_profile_runtimes.index_by(&:runtime_id)
    patch harbor.workspace_profile_path(@workspace), params: { workspace_profile: { workspace_profile_runtimes_attributes: {
      "0" => { id: rows[@cloud.id].id, runtime_id: @cloud.id, position: 1 },
      "1" => { id: rows[@laptop.id].id, runtime_id: @laptop.id, position: 0 } } } }
    assert_redirected_to harbor.workspace_profiles_path
    assert_equal [ @laptop, @cloud ], @workspace.reload.ordered_runtimes
    assert_equal 1, @changes

    delete harbor.workspace_profile_path(overflow)
    assert_equal "Workspace deleted.", flash[:notice]
    assert_not Harbor::WorkspaceProfile.exists?(overflow.id)
  end

  test "both pages can be switched off" do
    Harbor::Setting.set!(:page_runtimes, "false")
    get harbor.runtimes_path
    assert_response :not_found
    get harbor.workspace_profiles_path
    assert_response :success
    assert_select "[data-harbor-nav] a", text: "Runtimes", count: 0
  end
end
