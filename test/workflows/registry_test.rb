require "test_helper"

# What workflows are built from is one registered list: Harbor's own step
# types and trigger, and whatever a host registers beside them. The catalog
# the builder and the reference read is that list.
class HarborWorkflowsRegistryTest < ActiveSupport::TestCase
  include HarborWorkflows

  Catalog = Harbor::Workflows::Catalog

  test "Harbor's own step types need no host: agents, a note, the gates and calling a workflow" do
    assert_equal %w[agent verifier action filter choice loop approval call], Harbor::Workflows.step_types
    assert_equal %w[note], Harbor::Workflows.actions
    assert_equal %w[manual], Harbor::Workflows.trigger_kinds
    assert_empty Harbor::Workflows.claimable
    assert_empty Harbor::Workflows.setting_entries
  end

  test "every leaf type has something that runs it, and the engine walks the rest itself" do
    Harbor::Workflows.step_entries.each do |entry|
      if entry.structural
        assert_nil entry.runner, entry.id
      else
        assert_respond_to entry.runner_object, :start, entry.id
      end
    end
  end

  test "a host's step goes last, or beside the entry it names, and is found by type and action" do
    register_say
    assert_equal "action:say", Harbor::Workflows.step_entries.last.id
    Harbor::Workflows.register_step "action", action: "shout", label: "Shout", before: "action:note"
    Harbor::Workflows.register_step "deploy", label: "Deploy", after: "call"

    ids = Harbor::Workflows.step_entries.map(&:id)
    assert_equal [ "action:shout", "action:note" ], ids[ids.index("action:shout"), 2]
    assert_equal [ "call", "deploy" ], ids[ids.index("call"), 2]
    assert_equal "Say", Harbor::Workflows.step_for("type" => "action", "action" => "say").label
    assert_nil Harbor::Workflows.step_for("type" => "action", "action" => "whisper")
    assert_equal %w[shout note say], Harbor::Workflows.actions
    assert_raises(Harbor::Workflows::Unknown) { Harbor::Workflows.register_step "x", after: "nothing-like-it" }
  end

  test "registering an id again replaces the entry where it is, and one can be removed" do
    before = Harbor::Workflows.step_entries.map(&:id)
    Harbor::Workflows.register_step "agent", label: "Run our agent", runner: "HarborWorkflows::Recorder"

    assert_equal before, Harbor::Workflows.step_entries.map(&:id)
    assert_equal "Run our agent", Harbor::Workflows.step("agent").label
    assert_equal HarborWorkflows::Recorder, Harbor::Workflows.step("agent").runner_object

    Harbor::Workflows.remove_step "action:note"
    assert_equal before - [ "action:note" ], Harbor::Workflows.step_entries.map(&:id)
    assert_equal %w[agent verifier filter choice loop approval call], Harbor::Workflows.step_types
  end

  test "an entry is changed in part, keeping the rest and its place" do
    before = Harbor::Workflows.step_entries.map(&:id)
    Harbor::Workflows.update_step "call", defaults: { "input" => { "ticket" => "{{trigger.ticket}}" } }
    Harbor::Workflows.update_trigger "manual", group: "The desk"

    assert_equal before, Harbor::Workflows.step_entries.map(&:id)
    call = Harbor::Workflows.step("call")
    assert_equal [ { "input" => { "ticket" => "{{trigger.ticket}}" } }, "Run workflow", "Harbor::Workflows::Steps::Call", false ],
                 [ call.defaults, call.label, call.runner, call.inside_loop ]
    assert_equal [ "The desk", "Run by hand" ], Harbor::Workflows.trigger("manual").then { |t| [ t.group, t.label ] }
    assert_raises(Harbor::Workflows::Unknown) { Harbor::Workflows.update_step "teleport", label: "x" }
    assert_raises(Harbor::Workflows::Unknown) { Harbor::Workflows.update_trigger "telepathy", label: "x" }
  end

  test "a host's trigger, with how it is validated, summarized and matched" do
    Harbor::Workflows.register_trigger "ticket", before: "manual",
      label: "Ticket", group: "Desk", icon: "tag", color: "#123456", description: "A ticket changed.",
      fields: [ { name: "queue", label: "Queue", kind: "text" } ], defaults: { "queue" => "support" },
      summary_fields: %w[queue], summary_empty: "pick a queue",
      validate: ->(trigger, label) { trigger["queue"].blank? ? [ "#{label}: name a queue" ] : [] },
      summary: ->(trigger) { "Ticket in #{trigger['queue']}" },
      matches: ->(trigger, _event, data) { data["queue"] == trigger["queue"] }

    assert_equal %w[ticket manual], Harbor::Workflows.trigger_kinds
    assert Harbor::Workflows.trigger_matches?({ "kind" => "ticket", "queue" => "support" }, nil, { "queue" => "support" })
    refute Harbor::Workflows.trigger_matches?({ "kind" => "ticket", "queue" => "sales" }, nil, { "queue" => "support" })
    refute Harbor::Workflows.trigger_matches?({ "kind" => "manual" }, nil, {}), "a kind with no matcher never matches a delivery"
    listed = Catalog.triggers.first
    assert_equal [ "ticket", { "queue" => "support" }, %w[queue], "pick a queue" ], listed.values_at(:kind, :defaults, :summary_fields, :summary_empty)
  end

  test "data fields, settings and claims are registered too" do
    Harbor::Workflows.register_data :trigger, "queue", "string", "the ticket's queue", before: "sender"
    Harbor::Workflows.register_data :run, "ticket", "number", "the ticket this run is about"
    Harbor::Workflows.register_setting "channel", label: "Channel", kind: "select", options: -> { [ [ "a", "A" ] ] }, help: "Where it posts."
    Harbor::Workflows.register_claim "triage", "New tickets → TriageJob"

    assert_equal %w[kind queue sender], Catalog.data[:trigger].map(&:first)
    assert_equal %w[id url ticket], Catalog.data[:run].map(&:first)
    assert_equal [ { name: "channel", label: "Channel", kind: "select", options: [ [ "a", "A" ] ], help: "Where it posts." } ], Catalog.settings
    assert_equal({ "triage" => "New tickets → TriageJob" }, Harbor::Workflows.claimable)
    assert_raises(ArgumentError) { Harbor::Workflows.register_data :steps, "x", "string" }
  end

  test "a workflow may claim only the flows a host registered" do
    refute Harbor::Workflow.new(key: "w", name: "W", claims: %w[triage]).valid?
    Harbor::Workflows.register_claim "triage", "New tickets → TriageJob"
    assert Harbor::Workflow.new(key: "w", name: "W", claims: %w[triage]).valid?
  end

  # --- the catalog ---

  test "every step type and every action has a module, and every operator a label" do
    assert_equal Harbor::Workflows.step_types, Catalog.modules.map { |m| m[:type] }.uniq
    assert_equal Harbor::Workflows.actions, Catalog.modules.filter_map { |m| m[:action] }
    assert_equal Harbor::Workflows::Condition::OPS.sort, Catalog::OPERATORS.map { |o| o[:op] }.sort
  end

  test "a module's fields are complete, and its defaults make a step of its type" do
    register_say
    Catalog.modules.each do |m|
      step = { "key" => "s", "type" => m[:type], "name" => m[:label] }.merge(m[:defaults].deep_stringify_keys)
      step["action"] = m[:action] if m[:action]
      assert_equal m, Catalog.module_for(step), m[:label]
      m[:fields].each { |f| assert f[:name].present? && f[:label].present? && f[:kind].present?, "#{m[:label]}: #{f.inspect}" }
    end
  end

  test "the gates are the trigger filter, each step registered as one, and what a failure does" do
    assert_equal [ "Trigger filter", "Filter", "Router", "Repeat until", "Approval", "If it fails" ], Catalog.gates.map { |g| g[:name] }
    assert_equal [ nil, "filter", "choice", "loop", "approval", nil ], Catalog.gates.map { |g| g[:type] }

    Harbor::Workflows.register_step "pause", label: "Pause", gate: true, after: "loop", runner: "HarborWorkflows::Recorder",
      gate_note: { where: "a step on the path", reads: "—", does: "Waits a while." }
    assert_equal [ "Trigger filter", "Filter", "Router", "Repeat until", "Pause", "Approval", "If it fails" ], Catalog.gates.map { |g| g[:name] }
  end

  test "what is read from the host is read when it is asked for" do
    queues = %w[support]
    Harbor::Workflows.register_step "route", label: "Route", runner: "HarborWorkflows::Recorder",
      fields: -> { [ { name: "queue", label: "Queue", kind: "select", options: queues.map { |q| [ q, q ] } } ] }
    assert_equal [ %w[support support] ], Catalog.module_for("type" => "route")[:fields].first[:options]
    queues << "sales"
    assert_equal [ %w[support support], %w[sales sales] ], Catalog.module_for("type" => "route")[:fields].first[:options]
  end

  test "the builder is given everything at once, as JSON" do
    Harbor::TaskTypes.reset!
    Harbor::TaskTypes.declare "review"
    data = JSON.parse(Catalog.to_builder(workflows: [ { key: "a", name: "A" } ], agents: [], reference_url: "/factory/workflows/reference").to_json)
    assert_equal %w[agents data gates max_loop modules operators reference_url settings task_types triggers workflows], data.keys.sort
    assert_equal %w[review], data["task_types"]
    assert_equal 20, data["max_loop"]
    call = data["modules"].find { |m| m["type"] == "call" }
    assert_equal false, call["inside_loop"], "the builder doesn't offer it inside a loop"
  ensure
    Harbor::TaskTypes.reset!
  end
end
