require "test_helper"

# A host's subclass usually has the short name of the Harbor class it extends
# (`Run < Harbor::Run`). Associations have to reach the host's, not Harbor's.
class HarborHostClassesTest < ActiveSupport::TestCase
  test "every association to a configurable class names it absolutely" do
    {
      [ Harbor::RunEvent, :run ] => "::Harbor::Run",
      [ Harbor::WebhookEvent, :run ] => "::Harbor::Run",
      [ Harbor::Run, :parent_run ] => "::Harbor::Run",
      [ Harbor::Run, :child_runs ] => "::Harbor::Run",
      [ Harbor::ModelChoice, :model_alias ] => "::Harbor::ModelAlias",
      [ Harbor::Agent, :model_alias ] => "::Harbor::ModelAlias",
      [ Harbor::AgentDocument, :agent ] => "::Harbor::Agent",
      [ Harbor::TaskAssignment, :agent ] => "::Harbor::Agent",
      [ Harbor::Agent, :workspace_profile ] => "::Harbor::WorkspaceProfile",
      [ Harbor::Runtime, :runs ] => "::Harbor::Run",
      [ Harbor::WorkspaceProfileRuntime, :workspace_profile ] => "::Harbor::WorkspaceProfile",
      [ Harbor::WorkspaceProfileRuntime, :runtime ] => "::Harbor::Runtime"
    }.each do |(model, name), class_name|
      assert_equal class_name, model.reflect_on_association(name).class_name, "#{model}##{name}"
    end
  end

  test "a host class with the same short name as Harbor's is the one an association finds" do
    previous = Harbor.config.webhook_event_class
    Object.const_set(:WebhookEvent, Class.new(Harbor::WebhookEvent))
    Harbor.config.webhook_event_class = "WebhookEvent"
    probe = Class.new(Harbor::ApplicationRecord) do
      self.table_name = "runs"
      def self.name = "Harbor::Probe"
      belongs_to :relative, class_name: Harbor.config.webhook_event_class, foreign_key: :id
      belongs_to :absolute, class_name: Harbor.class_name_for(:webhook_event_class), foreign_key: :id
    end
    assert_equal Harbor::WebhookEvent, probe.reflect_on_association(:relative).klass, "what a relative name finds"
    assert_equal ::WebhookEvent, probe.reflect_on_association(:absolute).klass
    Harbor.config.webhook_event_class = "::WebhookEvent"
    assert_equal "::WebhookEvent", Harbor.class_name_for(:webhook_event_class), "an absolute name is left alone"
  ensure
    Harbor.config.webhook_event_class = previous
    Object.send(:remove_const, :WebhookEvent) if Object.const_defined?(:WebhookEvent, false)
  end
end
