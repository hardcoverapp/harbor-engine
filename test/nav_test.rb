require "test_helper"

class HarborNavTest < ActiveSupport::TestCase
  # Stands in for a view: a request path plus the two route scopes. A route
  # named in `missing` doesn't exist in this host.
  class Routes
    def initialize(missing = []) = @missing = missing
    def method_missing(name, *) = route?(name) ? "/#{name.to_s.delete_suffix('_path')}" : super
    def respond_to_missing?(name, include_private = false) = route?(name) || super

    private
      def route?(name) = name.to_s.end_with?("_path") && !@missing.include?(name)
  end

  View = Struct.new(:path, :missing) do
    def request = Struct.new(:path).new(path)
    def main_app = Routes.new(missing || [])
    def harbor = Routes.new
  end

  setup { @nav = Harbor::Nav.new }

  test "starts with Harbor's pages, Overview first" do
    assert_equal "Overview", @nav.labels.first
    assert_equal %w[Overview Velocity Workflows Automations], @nav.labels.first(4)
    assert_equal "Settings", @nav.labels.last
  end

  test "the host adds a page after a named one" do
    @nav.add "Database", :databases_path, after: "Automations"
    assert_equal %w[Workflows Automations Database], @nav.labels[2, 3]
    assert_equal :flows, @nav.items.find { |item| item.label == "Database" }.group, "next to a page means in its group"
  end

  test "before: places a page ahead, and no anchor appends" do
    @nav.add "First", :first_path, before: "Overview"
    @nav.add "Last", :last_path
    assert_equal "First", @nav.labels.first
    assert_equal "Last", @nav.labels.last
  end

  test "a duplicate label or an unknown anchor is refused" do
    assert_raises(ArgumentError) { @nav.add "Runs", :runs_path }
    assert_raises(ArgumentError) { @nav.add "X", :x_path, after: "Nowhere" }
    assert_raises(ArgumentError) { @nav.add "X", :x_path, after: "Runs", before: "Agents" }
  end

  test "remove drops a page" do
    @nav.remove "Velocity"
    assert_not_includes @nav.labels, "Velocity"
  end

  test "links resolve route helpers and mark the current page" do
    links = @nav.links(View.new("/runs/12"))
    runs = links.find { |link| link.label == "Runs" }
    assert_equal "/runs", runs.path
    assert runs.active
    assert_equal [ "Runs" ], links.select(&:active).map(&:label)
  end

  test "an item whose route the host doesn't have is left out" do
    labels = @nav.links(View.new("/", %i[velocity_path workflows_path])).map(&:label)
    assert_not_includes labels, "Velocity"
    assert_not_includes labels, "Workflows"
    assert_includes labels, "Runs"
    assert_includes labels, "Settings"
  end

  test "a path that only shares a prefix is not the page" do
    links = @nav.links(View.new("/runsheet"))
    assert links.none?(&:active)
  end

  test "also: prefixes count as the page" do
    links = @nav.links(View.new("/model_aliases/new"))
    assert_equal [ "Models" ], links.select(&:active).map(&:label)
  end

  test "an engine-scoped item resolves through the engine's routes" do
    assert_equal :harbor, @nav.items.find { |item| item.label == "Settings" }.scope
    @nav.add "Audit", :audit_path, scope: :harbor
    assert_equal "/audit", @nav.links(View.new("/")).find { |link| link.label == "Audit" }.path
  end

  test "a page switched off is left out" do
    Harbor::Setting.delete_all
    Harbor::Setting.set!(:page_velocity, "false")
    labels = @nav.links(View.new("/")).map(&:label)
    assert_not_includes labels, "Velocity"
    assert_includes labels, "Runs"
  ensure
    Harbor::Setting.delete_all
  end

  test "a page added with a key gets a switch" do
    @nav.add "Audit", :audit_path, key: :audit
    assert Harbor::Settings.declared?("page_audit")
    assert_equal :audit, @nav.items.last.key
  end

  def groups(nav, path = "/", missing = [])
    nav.groups(View.new(path, missing)).map { |group| [ group.key, group.heading, group.links.map(&:label) ] }
  end

  test "pages are grouped under headings, in Harbor's order" do
    assert_equal [
      [ :overview, nil, %w[Overview Velocity] ], [ :flows, "Flows", %w[Workflows Automations] ],
      [ :activity, "Activity", %w[Runs Webhooks] ], [ :agents, "Agents", %w[Agents Models] ],
      [ :infrastructure, "Infrastructure", %w[Runtimes Workspaces] ],
      [ :quality, "Quality", [ "Review policy", "Scorers", "Proposals" ] ], [ :settings, nil, %w[Settings] ]
    ], groups(@nav)
    assert_equal @nav.groups(View.new("/")).flat_map(&:links).map(&:label), @nav.links(View.new("/")).map(&:label)
  end

  test "a host's page joins the group it names" do
    @nav.add "Database", :databases_path, group: :infrastructure, icon: :database
    infrastructure = groups(@nav).find { |key, _| key == :infrastructure }
    assert_equal %w[Runtimes Workspaces Database], infrastructure.last
    assert_equal :database, @nav.groups(View.new("/")).flat_map(&:links).find { |link| link.label == "Database" }.icon
  end

  test "a group the host names itself comes after Harbor's and before Settings; a page with none goes in More" do
    @nav.add "Invoices", :invoices_path, group: :billing
    @nav.add "Audit", :audit_path
    keys = groups(@nav).map(&:first)
    assert_equal %i[quality billing more settings], keys.last(4)
    assert_equal "Billing", groups(@nav).find { |key, _| key == :billing }[1]
  end

  test "a group with no page to show is left out, heading and all" do
    missing = %i[reviews_path scorers_path improvement_proposals_path]
    assert_not_includes groups(@nav, "/", missing).map(&:first), :quality
  end

  test "Workflows is current on its runs pages, which sit outside its path" do
    assert_equal [ "Workflows" ], @nav.links(View.new("/workflow_runs/76")).select(&:active).map(&:label)
  end

  test "every page of the menu has an icon of its own" do
    icons = @nav.items.map(&:icon)
    assert_equal icons.size, icons.uniq.size
    icons.each { |icon| assert Harbor::Icons::PATHS.key?(icon), "no icon named #{icon}" }
    assert_equal Harbor::Icons::PATHS[:page], Harbor::Icons.markup(:nope)
    assert_equal "<circle/>", Harbor::Icons.markup("<circle/>")
  end

  test "items is a copy" do
    @nav.items.clear
    assert @nav.labels.any?
  end
end
