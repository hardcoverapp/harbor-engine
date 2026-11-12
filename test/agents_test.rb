require "test_helper"

class HarborAgentsTest < ActiveSupport::TestCase
  setup do
    [ Harbor::TaskAssignment, Harbor::AgentDocument, Harbor::Agent, Harbor::AgentSetting ].each(&:delete_all)
    Harbor::TaskTypes.reset!
    Harbor::TaskTypes.declare "review"
    Harbor::TaskTypes.declare "rebase", fallback: "review"
    Harbor::TaskTypes.declare "triage", default_agent: "planner", executor: "bridge"
    @writer = Harbor::Agent.create!(key: "writer", name: "Wren", system_prompt: "Write plainly.")
  end

  teardown { Harbor::TaskTypes.reset! }

  test "an agent needs a well-formed key and JSON of the right shape" do
    assert_not Harbor::Agent.new(key: "Has Spaces").valid?
    assert_not Harbor::Agent.new(key: "writer").valid?, "keys are unique"
    bad = Harbor::Agent.new(key: "bad", tools: [], configuration: "x", default_tasks: {})
    assert_not bad.valid?
    assert_equal %i[configuration default_tasks tools], bad.errors.attribute_names.sort
    assert_equal "Wren", @writer.display_name
    assert_equal "plain", Harbor::Agent.new(key: "plain").display_name
  end

  test "the full system prompt is the shared context, then the agent's prompt, then its documents" do
    Harbor::AgentSetting.create!(key: "house_context", body: "Be kind.")
    Harbor::AgentSetting.create!(key: "shared/glossary.md", body: "Terms.")
    Harbor::AgentSetting.create!(key: "unrelated", body: "Not shared.")
    @writer.agent_documents.create!(path: "style/tone.md", body: "Warm.")
    assert_equal [ "Be kind.", "# glossary.md\n\nTerms.", "Write plainly.", "# style/tone.md\n\nWarm." ],
                 @writer.reload.full_system_prompt.split("\n\n---\n\n")
  end

  test "a document is a relative Markdown path, unique per agent, and never AGENT.md" do
    @writer.agent_documents.create!(path: "notes.md", body: "x")
    %w[notes.md /abs.md ../up.md a/../b.md notes.txt AGENT.md].each do |path|
      assert_not @writer.agent_documents.build(path: path).valid?, path
    end
    assert_difference("Harbor::AgentDocument.count", -1) { @writer.destroy }
  end

  test "an avatar is stored from an upload, checked, and removable" do
    png = StringIO.new(Base64.decode64("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="))
    @writer.update!(avatar: png)
    assert @writer.avatar?
    assert_equal "image/png", @writer.avatar_content_type
    assert_not @writer.update(avatar: StringIO.new("just text"))
    assert_includes @writer.errors[:avatar], "must be a PNG, JPEG, GIF, or WebP image"
    stored = Harbor::Agent.find(@writer.id)
    assert stored.avatar?, "a rejected upload leaves the stored one alone"
    stored.update!(remove_avatar: true)
    assert_not stored.reload.avatar?
  end

  test "task types are declared once, in order, with what the host adds kept" do
    assert_equal %w[review rebase triage], Harbor::TaskTypes.keys
    assert_equal({ executor: "bridge" }, Harbor::TaskTypes.find("triage").details)
    assert_raises(ArgumentError) { Harbor::TaskTypes.declare "review" }
    assert_raises(Harbor::TaskTypes::Unknown) { Harbor::TaskTypes.find("nope") }
  end

  test "an assignment is for a declared task type" do
    assert_not Harbor::TaskAssignment.new(task_type: "nope", agent_key: "writer").valid?
    assert Harbor::TaskAssignment.new(task_type: "review", agent_key: "writer").valid?
    assert_equal [ @writer ], Harbor::TaskAssignment.compatible_agents("review").to_a
  end

  test "agent_for uses the type's own row, then its fallback's, then its default agent" do
    assert_nil Harbor::TaskAssignment.agent_for("review")
    Harbor::TaskAssignment.create!(task_type: "review", agent_key: "writer")
    assert_equal @writer, Harbor::TaskAssignment.agent_for("review")
    assert_equal @writer, Harbor::TaskAssignment.agent_for(:rebase), "no row of its own: the fallback type's agent"

    assert_nil Harbor::TaskAssignment.agent_for("triage")
    planner = Harbor::Agent.create!(key: "planner")
    assert_equal planner, Harbor::TaskAssignment.agent_for("triage")
    Harbor::TaskAssignment.create!(task_type: "triage", agent_key: "writer")
    assert_equal @writer, Harbor::TaskAssignment.agent_for("triage"), "a row always wins"

    @writer.update!(enabled: false)
    assert_nil Harbor::TaskAssignment.agent_for("review"), "a switched-off agent isn't dispatched to"
    assert_nil Harbor::TaskAssignment.agent_for("undeclared")
  end
end
