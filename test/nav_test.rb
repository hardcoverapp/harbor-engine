require "test_helper"

class HarborNavTest < ActiveSupport::TestCase
  # Stands in for a view: a request path plus the two route scopes.
  class Routes
    def method_missing(name, *) = name.to_s.end_with?("_path") ? "/#{name.to_s.delete_suffix('_path')}" : super
    def respond_to_missing?(name, include_private = false) = name.to_s.end_with?("_path") || super
  end

  View = Struct.new(:path) do
    def request = Struct.new(:path).new(path)
    def main_app = Routes.new
    def harbor = Routes.new
  end

  setup { @nav = Harbor::Nav.new }

  test "starts with Harbor's pages, Overview first" do
    assert_equal "Overview", @nav.labels.first
    assert_equal %w[Overview Velocity Automations Workflows], @nav.labels.first(4)
    assert_equal "Settings", @nav.labels.last
  end

  test "the host adds a page after a named one" do
    @nav.add "Database", :databases_path, after: "Automations"
    assert_equal %w[Automations Database Workflows], @nav.labels[2, 3]
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
    assert_equal "/audit", @nav.links(View.new("/")).last.path
  end

  test "items is a copy" do
    @nav.items.clear
    assert @nav.labels.any?
  end
end
