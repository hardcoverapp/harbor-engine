require "test_helper"

class HarborRuntimesTest < ActiveSupport::TestCase
  # A backend the tests control: which providers it runs, and its health.
  class TestBackend < Harbor::Runtimes::Backend
    class << self
      attr_accessor :providers, :unready, :healthy
      def label = "Test"
      def supports?(choice, **) = providers.nil? || providers.include?(choice.model_provider.key)
    end

    def unready_reason = self.class.unready
    def health_check = self.class.healthy == false ? raise("no answer") : true
  end

  class StrictBackend < TestBackend
    def self.enforces_tool_policy? = true
  end

  setup do
    [ Harbor::TaskAssignment, Harbor::AgentDocument, Harbor::Agent, Harbor::WorkspaceProfileRuntime, Harbor::WorkspaceProfile,
      Harbor::Run, Harbor::Runtime, Harbor::ModelChoice, Harbor::ModelAlias, Harbor::ModelProvider ].each(&:delete_all)
    Harbor::Runtimes.register "test", "HarborRuntimesTest::TestBackend"
    Harbor::Runtimes.register "strict", "HarborRuntimesTest::StrictBackend"
    [ TestBackend, StrictBackend ].each { |b| b.providers = nil; b.unready = nil; b.healthy = nil }
    HARBOR_TEST_REDIS.with { |r| r.call("KEYS", "harbor:test:slots:*").each { |k| r.call("DEL", k) } }

    @anthropic = Harbor::ModelProvider.create!(key: "anthropic")
    @openai = Harbor::ModelProvider.create!(key: "openai")
    @alias = Harbor::ModelAlias.create!(name: "Thinking", model_choices_attributes: [
      { model_provider: @anthropic, model: "claude-new", position: 0 }, { model_provider: @openai, model: "gpt-new", position: 1 } ])
    @cloud = Harbor::Runtime.create!(key: "cloud", name: "Cloud", backend: "test", max_concurrent: 1, position: 0)
    @laptop = Harbor::Runtime.create!(key: "laptop", name: "Laptop", backend: "strict", max_concurrent: 2, position: 1)
    @workspace = Harbor::WorkspaceProfile.create!(name: "Default", workspace_profile_runtimes_attributes: [
      { runtime: @cloud, position: 0 }, { runtime: @laptop, position: 1 } ])
    @agent = Harbor::Agent.create!(key: "writer", model_alias: @alias, workspace_profile: @workspace)
  end

  teardown do
    Harbor::Runtimes.unregister "test"
    Harbor::Runtimes.unregister "strict"
    Harbor.config.sticky_runtime = nil
  end

  test "a runtime names a registered backend and has a positive limit" do
    assert_not Harbor::Runtime.new(key: "x", name: "X", backend: "nope").valid?
    assert_not Harbor::Runtime.new(key: "x", name: "X", backend: "test", max_concurrent: 0).valid?
    assert_not Harbor::Runtime.new(key: "Bad Key", name: "X", backend: "test").valid?
    assert_equal TestBackend, @cloud.backend_class
    assert_raises(Harbor::Runtimes::UnknownBackend) { Harbor::Runtimes.backend("nope") }
  end

  test "a workspace takes its key from its name and needs a runtime" do
    assert_equal "default", @workspace.key
    assert_equal [ @cloud, @laptop ], @workspace.ordered_runtimes
    empty = Harbor::WorkspaceProfile.new(name: "Empty")
    assert_not empty.valid?
    assert_includes empty.errors.full_messages, "Add at least one runtime."
    assert_not @cloud.destroy, "a runtime in a workspace can't be deleted"
  end

  test "a runtime is unavailable when off, unready, or recently failed a check" do
    assert_nil @cloud.unavailable_reason
    assert @cloud.healthy?
    @cloud.update!(enabled: false)
    assert_equal "disabled", @cloud.unavailable_reason
    @cloud.update!(enabled: true)
    TestBackend.unready = "not set up"
    assert_equal "not set up", @cloud.unavailable_reason
    TestBackend.unready = nil

    TestBackend.healthy = false
    assert_not @cloud.check_health!
    assert_match "unhealthy: RuntimeError: no answer", @cloud.unavailable_reason
    travel(Harbor::Runtime::HEALTH_TTL + 1.minute) { assert_nil @cloud.reload.unavailable_reason }
    TestBackend.healthy = true
    assert @cloud.check_health!
    assert_nil @cloud.unavailable_reason
  end

  test "slots count sessions and workspaces, are owner-checked, and expire" do
    holder = Harbor::Slots::Capacity.new("line", 2, 1)
    first = Harbor::Slots.acquire(holder, "a", ttl: 60, workspace: "shared")
    assert_equal 0, first
    assert_equal 1, Harbor::Slots.acquire(holder, "b", ttl: 60, workspace: "shared"), "sharing a workspace counts once"
    assert_nil Harbor::Slots.acquire(holder, "c", ttl: 60, workspace: "shared"), "two sessions is the limit"
    assert_equal [ 2, 1 ], Harbor::Slots.counts(holder)
    assert_equal 0, Harbor::Slots.free(holder)

    Harbor::Slots.release("line", first, "someone-else")
    assert_equal 2, Harbor::Slots.busy(holder), "only the owner gives a slot back"
    Harbor::Slots.release("line", first, "a")
    assert_nil Harbor::Slots.acquire(holder, "d", ttl: 60), "a second workspace is over the limit"
    assert_equal 0, Harbor::Slots.acquire(holder, "d", ttl: 60, workspace: "shared")

    travel(2.minutes) { assert_equal [ 0, 0 ], Harbor::Slots.counts(holder) }
    Harbor::Slots.clear("line")
  end

  test "placement uses the first runtime that can run the agent, and says why it skipped others" do
    placed = @agent.placement
    assert_equal @cloud, placed.runtime
    assert_equal "claude-new", placed.choice.model
    assert_equal "using Cloud", placed.summary

    @cloud.update!(enabled: false)
    placed = @agent.placement
    assert_equal @laptop, placed.runtime
    assert_equal "Cloud: disabled; using Laptop", placed.summary
  end

  test "runtime and model fall back together" do
    TestBackend.providers = [ "openai" ]
    assert_equal [ @cloud, "gpt-new" ], @agent.placement.then { |p| [ p.runtime, p.choice.model ] }
    @openai.update!(enabled: false)
    placed = @agent.placement
    assert_equal [ @laptop, "claude-new" ], [ placed.runtime, placed.choice.model ]
    assert_match "Cloud: no available model for Thinking here", placed.summary
  end

  test "work that needs its tool policy enforced only goes where it is" do
    assert_equal @laptop, @agent.placement(requirements: { tool_policy: true }).runtime
  end

  test "taking capacity fills a runtime, moves on, then waits" do
    one = @agent.placement(capacity: { owner: "run-1", ttl: 60 })
    assert_equal [ @cloud, 0 ], [ one.runtime, one.slot ]
    assert_equal "1/1 busy", @cloud.usage_label
    two = @agent.placement(capacity: { owner: "run-2", ttl: 60 })
    assert_equal @laptop, two.runtime
    assert_equal "Cloud: 1/1 busy; using Laptop", two.summary
    @agent.placement(capacity: { owner: "run-3", ttl: 60 })
    waiting = @agent.placement(capacity: { owner: "run-4", ttl: 60 })
    assert waiting.waiting?
    assert_equal "Cloud: 1/1 busy; Laptop: 2/2 busy", waiting.summary

    Harbor::Runtimes::Slots.release("cloud", one.slot, "run-1")
    assert_equal @cloud, @agent.placement(capacity: { owner: "run-4", ttl: 60 }).runtime
    Harbor::Runtimes::Slots.release_stale!
    assert_equal 0, @laptop.busy, "nothing is running, so leftover leases are dropped"
  end

  test "nothing able to run the agent raises the workspace's Unavailable, a model alias's" do
    @cloud.update!(enabled: false)
    @laptop.update!(enabled: false)
    error = assert_raises(Harbor::WorkspaceProfile::Unavailable) { @agent.placement }
    assert_kind_of Harbor::ModelAlias::Unavailable, error
    assert_match "No runtime in the Default workspace can run writer: Cloud: disabled; Laptop: disabled", error.message
    assert_raises(Harbor::WorkspaceProfile::Unavailable) { Harbor::Agent.create!(key: "homeless", model_alias: @alias).placement }
  end

  test "a runtime holding the run's workspace goes first, and a required one is waited for" do
    run = Harbor::Run.create!(skill: "writer.fix", status: "queued")
    hold = Harbor::Runtimes::Placement::Hold.new(runtime: @laptop, reason: "its branch is there")
    Harbor.config.sticky_runtime = ->(r) { hold if r == run }
    placed = @agent.placement(run: run)
    assert_equal @laptop, placed.runtime
    assert placed.sticky
    assert_equal "using Laptop, which holds the live workspace (its branch is there)", placed.summary
    assert_equal @cloud, @agent.placement.runtime, "other runs are placed as usual"

    @laptop.update!(enabled: false)
    assert_equal @cloud, @agent.placement(run: run).runtime, "an optional hold that can't be used starts fresh"
    hold.required = true
    error = assert_raises(Harbor::WorkspaceProfile::Unavailable) { @agent.placement(run: run) }
    assert_match "Laptop holds the workspace this run needs", error.message
  end

  test "a host's alias subclass raises its own Unavailable" do
    host_alias = Class.new(Harbor::ModelAlias) { const_set(:Unavailable, Class.new(Harbor::ModelAlias::Unavailable)) }
    @anthropic.update!(enabled: false)
    @openai.update!(enabled: false)
    error = assert_raises(Harbor::ModelAlias::Unavailable) { host_alias.find(@alias.id).resolve }
    assert_instance_of host_alias::Unavailable, error
  end
end
