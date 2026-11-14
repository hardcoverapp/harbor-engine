require "test_helper"

# A definition is checked when it is saved, against what is registered, and
# every save that changes it is a new version.
class HarborWorkflowsDefinitionTest < ActiveSupport::TestCase
  include HarborWorkflows

  Definition = Harbor::Workflows::Definition
  Condition = Harbor::Workflows::Condition
  Context = Harbor::Workflows::Context

  def parse(**definition) = Definition.parse(definition.deep_stringify_keys)

  test "the definition a new workflow starts as is valid" do
    definition = Definition.parse(Harbor::WorkflowsController.starter)
    assert definition.valid?, definition.errors.join("; ")
  end

  test "saving explains what's wrong instead of admitting a graph that can't finish" do
    register_say
    d = parse(
      triggers: [ { kind: "telepathy" }, { kind: "manual", conditions: { path: "trigger.sender", op: "resembles" } } ],
      steps: [
        { key: "rounds", type: "loop", steps: [ { key: "inner", type: "call", workflow: "other" } ] },
        { key: "rounds", type: "agent", agent: "writer" },
        { key: "Bad Key", type: "teleport" },
        { key: "check", type: "verifier", agent: "writer", prompt: "check {{steps.nope.text}}", verdicts: %w[only] },
        { key: "sing", type: "action", action: "sing" },
        { key: "route", type: "choice", branches: [ { steps: [] } ] },
        { key: "go", type: "call" }
      ]
    )
    refute d.valid?
    joined = d.errors.join("\n")
    assert_match(/Trigger 1: kind must be one of manual/, joined)
    assert_match(/Trigger 2: op must be one of/, joined)
    assert_match(/rounds: a loop needs max_iterations between 1 and 20/, joined)
    assert_match(/inner: call can't sit inside a loop/, joined)
    assert_match(/rounds: key is used twice/, joined)
    assert_match(/rounds: give either a prompt or a slash command/, joined)
    assert_match(/Bad Key: key must be lowercase/, joined)
    assert_match(/Bad Key: type must be one of agent, verifier, action, filter, choice, loop, approval, call/, joined)
    assert_match(/check: a verifier lists at least two verdicts/, joined)
    assert_match(/sing: action must be one of note, say/, joined)
    assert_match(/route: branch 1 has no condition/, joined)
    assert_match(/go: name the workflow to call/, joined)
    assert_match(/steps.nope, but there's no step/, joined)
  end

  test "a workflow needs a trigger and a step, a filter a condition, and inputs valid names" do
    assert_equal [ "Give at least one trigger", "Give at least one step" ], Definition.parse({}).tap(&:validate).errors

    d = parse(inputs: [ { key: "branch" }, { key: "Bad Name" } ], triggers: [ { kind: "manual" } ], steps: [ { key: "gate", type: "filter" } ])
    refute d.valid?
    assert_includes d.errors, "gate: a filter needs a condition"
    assert_includes d.errors, "Input 2: name must be lowercase letters, digits and _"
    assert_equal [ { "key" => "branch" }, { "key" => "Bad Name" } ], d.inputs
  end

  test "bad JSON is a readable error" do
    d = Definition.parse("{ nope")
    refute d.valid?
    assert_match(/Not valid JSON/, d.errors.first)
  end

  test "a host's step type and trigger are checked by what they registered" do
    Harbor::Workflows.register_step "deploy", label: "Deploy", runner: "HarborWorkflows::Recorder", inside_loop: false,
      validate: ->(step, label) { step["to"].blank? ? [ "#{label}: say where to" ] : [] }
    Harbor::Workflows.register_trigger "ticket", label: "Ticket",
      validate: ->(trigger, label) { trigger["queue"].blank? ? [ "#{label}: name a queue" ] : [] }

    d = parse(triggers: [ { kind: "ticket" } ],
              steps: [ { key: "ship", type: "deploy" },
                       { key: "again", type: "loop", max_iterations: 2, steps: [ { key: "inside", type: "deploy", to: "staging" } ] } ])
    refute d.valid?
    assert_equal [ "Trigger 1: name a queue", "ship: say where to", "inside: deploy can't sit inside a loop" ], d.errors

    assert parse(triggers: [ { kind: "ticket", queue: "support" } ], steps: [ { key: "ship", type: "deploy", to: "staging" } ]).valid?
  end

  test "a host checks a whole definition with a validator" do
    Harbor::Workflows.register_validator ->(definition) { definition.settings["channel"].blank? ? [ "settings.channel is needed" ] : [] }
    d = parse(triggers: [ { kind: "manual" } ], steps: [ { key: "ok", type: "approval" } ])
    refute d.valid?
    assert_equal [ "settings.channel is needed" ], d.errors
    assert parse(settings: { channel: "a" }, triggers: [ { kind: "manual" } ], steps: [ { key: "ok", type: "approval" } ]).valid?
  end

  test "each_step walks branches and loops with the containers above each step" do
    d = parse(triggers: [ { kind: "manual" } ],
              steps: [ { key: "route", type: "choice", branches: [ { when: { path: "a", op: "present" }, steps: [ { key: "yes", type: "approval" } ] } ],
                         otherwise: [ { key: "no", type: "approval" } ] },
                       { key: "again", type: "loop", max_iterations: 2, steps: [ { key: "inside", type: "approval" } ] } ],
              finally: [ { key: "bye", type: "approval" } ])
    assert d.valid?, d.errors.join("; ")
    assert_equal %w[route yes no again inside bye], d.each_step.map { |step, _| step["key"] }
    assert_equal({ "yes" => %w[route], "inside" => %w[again], "bye" => [] },
                 d.each_step.to_h { |step, parents| [ step["key"], parents.map { |p| p["key"] } ] }.slice("yes", "inside", "bye"))
    assert_equal "approval", d.find("inside")["type"]
  end

  # --- conditions and the context they read ---

  test "conditions are data: all/any/not over context paths" do
    ctx = Context.new("steps" => { "review" => { "verdict" => "Changes", "score" => "7" } }, "trigger" => { "labels" => %w[bug ui], "draft" => false })
    assert Condition.evaluate({ "path" => "steps.review.verdict", "op" => "eq", "value" => "changes" }, ctx)
    assert Condition.evaluate({ "all" => [ { "path" => "trigger.labels", "op" => "contains", "value" => "ui" },
                                           { "not" => { "path" => "steps.review.verdict", "op" => "in", "values" => %w[approve] } } ] }, ctx)
    refute Condition.evaluate({ "any" => [ { "path" => "steps.missing", "op" => "present" } ] }, ctx)
    assert Condition.evaluate({ "path" => "trigger.draft", "op" => "present" }, ctx), "false is a value"
    assert Condition.evaluate({ "path" => "steps.review.score", "op" => "gte", "value" => 7 }, ctx)
    refute Condition.evaluate({ "path" => "steps.review.score", "op" => "lt", "value" => 7 }, ctx)
    assert Condition.evaluate(nil, ctx), "no condition always passes"
    assert_equal "steps.review.verdict in approve, comment",
                 Condition.describe({ "path" => "steps.review.verdict", "op" => "in", "values" => %w[approve comment] })
    assert_equal [ "a condition needs a path", "op must be one of #{Condition::OPS.join(', ')}" ], Condition.validate({ "op" => "like" })
  end

  test "templates read the context by path and leave what they can't find as written" do
    ctx = Context.new("input" => { "branch" => "main" }, "steps" => { "list" => { "items" => [ { "name" => "a" } ] } })
    assert_equal "on main, first a, {{steps.gone.text}}", ctx.render("on {{input.branch}}, first {{ steps.list.items.0.name }}, {{steps.gone.text}}")
    assert_equal({ "a" => [ "main" ], "n" => 3 }, ctx.render_deep("a" => [ "{{input.branch}}" ], "n" => 3))
    assert_equal %w[review fix], Context.sources("{{steps.review.feedback}} then {{steps.fix.text}} and {{input.x}}")

    ctx.record("ping", { "said" => "one" }, iteration: 1)
    ctx.record("ping", { "said" => "two" }, iteration: 2)
    assert_equal "two", ctx.dig_path("steps.ping.said")
    assert_equal %w[one two], ctx.dig_path("steps.ping.iterations").map { |pass| pass["said"] }
  end

  # --- versions ---

  test "saving a definition makes a version only when it changed, and exports the latest" do
    exported = {}
    Harbor.config.export = ->(path, body) { exported[path] = body }
    workflow = Harbor::Workflow.new(key: "def-#{SecureRandom.hex(3)}", name: "Def", description: "What it is for")
    data = Harbor::WorkflowsController.starter
    v1, = workflow.save_definition!(data)
    v_same, = workflow.save_definition!(data.to_json)
    assert_equal v1, v_same
    v2, = workflow.save_definition!(data.merge("inputs" => [ { "key" => "branch" } ]))

    assert_equal [ 1, 2 ], workflow.versions.reload.map(&:number)
    assert_equal v2, workflow.reload.current_version
    kept = JSON.parse(exported.fetch("workflows/#{workflow.key}.json"))
    assert_equal [ workflow.key, "Def", "What it is for", [], 2 ], kept.values_at("key", "name", "description", "claims", "version")
    assert_equal v2.definition, kept["definition"]
  end

  test "a definition that isn't valid saves nothing and says why; a failing export never fails the save" do
    workflow = Harbor::Workflow.new(key: "def-#{SecureRandom.hex(3)}", name: "Def")
    version, errors = workflow.save_definition!({ "triggers" => [ { "kind" => "manual" } ], "steps" => [] })
    assert_nil version
    assert_equal [ "Give at least one step" ], errors
    refute workflow.persisted?

    Harbor.config.export = ->(*) { raise "the disk is full" }
    version, errors = workflow.save_definition!(Harbor::WorkflowsController.starter)
    assert_equal [ 1, [] ], [ version.number, errors ]
  end
end
