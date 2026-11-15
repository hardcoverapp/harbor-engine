require "test_helper"

# Overview's building blocks: the stages and what a host declares beside
# them, the snapshot each stage's parts read, run timings in SQL, the changes
# feed's sources, the numbers at a glance, and the stage note.
class HarborOverviewRegistryTest < ActiveSupport::TestCase
  include HarborOverviewSetup

  test "a site that declares nothing has one stage, which holds everything" do
    stage = Harbor::Overview.stages.sole
    assert_equal [ "work", "Work", true, "stage-work" ], [ stage.key, stage.title, stage.everything, stage.anchor ]
    assert_not Harbor::Overview.stages_declared?
    assert_equal stage, Harbor::Overview.find_stage("work")
    assert_equal stage, Harbor::Overview.stage_for_task("anything")
    assert_nil Harbor::Overview.find_stage("ship")
  end

  test "declared stages come in the order declared, and declaring one again replaces it where it is" do
    declare_stages
    assert_equal %w[triage review ship], Harbor::Overview.stages.map(&:key)
    assert Harbor::Overview.stages_declared?
    Harbor::Overview.stage "review", title: "Second look", task_types: %w[review]
    assert_equal [ "Triage", "Second look", "Ship" ], Harbor::Overview.stages.map(&:title)
    assert_equal "review", Harbor::Overview.stage_for_task("review").key
    assert_nil Harbor::Overview.stage_for_task("audit")
    assert Harbor::Overview.find_stage("triage").starts_on?("kind" => "ticket")
    assert_not Harbor::Overview.find_stage("triage").starts_on?("kind" => "manual")
    assert_not Harbor::Overview.find_stage("ship").starts_on?("kind" => "ticket"), "a stage that names no trigger starts on none"
  end

  test "steering rows, ways in, parts, tiles and change sources are kept by key, in the order declared" do
    Harbor::Overview.steer "hold", want: "Pause it", action: "add `hold`", result: "work stops", stage: "review"
    Harbor::Overview.steer "ship", want: "Ship it", action: "merge", result: "it goes out", stage: :ship
    Harbor::Overview.steer "hold", want: "Pause", action: "add `hold`", result: "work stops", stage: "review"
    assert_equal [ "Pause", "Ship it" ], Harbor::Overview.steering.map(&:want)
    assert_equal [ "Ship it" ], Harbor::Overview.steering_for("ship").map(&:want)

    Harbor::Overview.way_in "desk", title: "The help desk", body: "A ticket.", stage: "triage", task_type: :triage
    assert_equal [ [ "desk", "triage", "triage" ] ], Harbor::Overview.ways_in.map { |way| [ way.key, way.stage, way.task_type ] }

    Harbor::Overview.part(:checks, "Checks") { |_stage, _snapshot| [] }
    Harbor::Overview.part(:sign_offs) { |_stage, _snapshot| [] }
    assert_equal [ [ :checks, "Checks" ], [ :sign_offs, "Sign offs" ] ], Harbor::Overview.parts.map { |part| [ part.name, part.title ] }

    Harbor::Overview.tile(:tickets, label: "Tickets", after: :runs) { |_since| { value: 3 } }
    assert_equal [ [ :tickets, :runs ] ], Harbor::Overview.tiles.map { |tile| [ tile.key, tile.after ] }
  end

  test "a host's section sits where it is declared, and one of Harbor's can be left out" do
    assert_equal %w[summary ways_in lifecycle steering changes], Harbor::Overview.sections.map(&:key)
    assert_equal "harbor/overview/lifecycle", Harbor::Overview.sections[2].partial
    Harbor::Overview.section :costs, partial: "host/overview/costs", after: :lifecycle
    Harbor::Overview.section :first, partial: "host/overview/first", before: "summary"
    Harbor::Overview.section :last, partial: "host/overview/last"
    assert_equal %w[first summary ways_in lifecycle costs steering changes last], Harbor::Overview.sections.map(&:key)
    Harbor::Overview.hide_section :summary
    Harbor::Overview.section :costs, partial: "host/overview/costs", before: :changes
    assert_equal %w[first ways_in lifecycle steering costs changes last], Harbor::Overview.sections.map(&:key)
    assert_raises(ArgumentError) { Harbor::Overview.section :x, partial: "x", after: :nowhere }
    assert_raises(ArgumentError) { Harbor::Overview.section :x, partial: "x", after: :changes, before: :changes }
  end
end

class HarborOverviewSnapshotTest < ActiveSupport::TestCase
  include HarborOverviewSetup

  test "routing mirrors TaskAssignment.agent_for, with the agent's model and effort" do
    snapshot = Harbor::Overview::Snapshot.new
    assert_equal [ "writer", "assigned", "Thinking", "high" ], snapshot.route("review").then { |r| [ r.agent.key, r.source, r.model, r.effort ] }
    assert_equal [ "writer", "falls back to review" ], snapshot.route("rebase").then { |r| [ r.agent.key, r.source ] }
    assert_equal [ "planner", "default", nil, nil ], snapshot.route("triage").then { |r| [ r.agent.key, r.source, r.model, r.effort ] }
    assert_equal [ nil, "unassigned" ], snapshot.route("audit").then { |r| [ r.agent, r.source ] }
    %w[review rebase triage].each do |type|
      assert_equal Harbor::TaskAssignment.agent_for(type), snapshot.route(type).agent, type
    end
    assert_nil Harbor::TaskAssignment.agent_for("audit")

    @writer.update!(enabled: false)
    assert_equal "unassigned", Harbor::Overview::Snapshot.new.route("review").source, "an agent switched off does no work"
  end

  test "with no stages declared, the one stage holds every task type, workflow, automation and timing" do
    workflow("tidy", "Tidy up", manual([ agent_step("writer") ]))
    automation("sweep", "Sweep")
    finished("review", minutes: 3)
    finished("undeclared", minutes: 1)
    snapshot = Harbor::Overview::Snapshot.new
    stage = snapshot.stages.sole
    parts = snapshot.parts_for(stage)
    assert_equal %w[review rebase triage audit], parts[:routing].call.map(&:task_type)
    assert_equal [ "Tidy up" ], parts[:workflows].call.map(&:name)
    assert_equal [ "Sweep" ], parts[:automations].call.map(&:name)
    assert_equal %w[review undeclared], parts[:timings].call.map(&:task_type)
    assert_empty snapshot.unplaced_workflows + snapshot.unplaced_automations
    assert_empty snapshot.unplaced_task_types
  end

  test "a workflow sits in the stage that claims its flow, else starts on its trigger, else does its first agent step's task" do
    declare_stages
    Harbor::Workflows.register_claim "reviewing", "Review asked for → ReviewJob"
    Harbor::Workflows.register_trigger "ticket", label: "Ticket", group: "Desk", icon: "tag", color: "#0F766E", description: "A ticket."
    claimed = workflow("claimed", "Claimed", manual([ agent_step("task:triage") ]), claims: %w[reviewing])
    started = workflow("started", "Started", { "triggers" => [ { "kind" => "manual" }, { "kind" => "ticket" } ], "steps" => [ agent_step("task:review") ] })
    by_task = workflow("by-task", "By task", manual([ agent_step("writer"), agent_step("task:rebase").merge("key" => "again") ]))
    loose = workflow("loose", "Loose", manual([ agent_step("writer") ]))

    snapshot = Harbor::Overview::Snapshot.new
    stage = ->(key) { Harbor::Overview.find_stage(key) }
    assert_equal [ started ], snapshot.workflows_for(stage.("triage"))
    assert_equal [ by_task, claimed ], snapshot.workflows_for(stage.("review"))
    assert_empty snapshot.workflows_for(stage.("ship"))
    assert_equal [ loose ], snapshot.unplaced_workflows
  end

  test "an automation sits in the stage that names it, else the one that starts on what starts it" do
    declare_stages
    Harbor::Overview.stage "nightly", title: "Nightly", starts_on: ->(trigger) { trigger["kind"] == "schedule" }
    named = automation("sweep", "Sweep")
    scheduled = automation("report", "Report")
    by_hand = automation("fix", "Fix", trigger_kind: "manual", cron: nil)
    assert_equal [ { "kind" => "schedule" } ], scheduled.trigger_data

    snapshot = Harbor::Overview::Snapshot.new
    assert_equal [ named ], snapshot.automations_for(Harbor::Overview.find_stage("triage"))
    assert_equal [ scheduled ], snapshot.automations_for(Harbor::Overview.find_stage("nightly"))
    assert_equal [ by_hand ], snapshot.unplaced_automations
    assert_equal %w[audit], snapshot.unplaced_task_types
  end

  test "a host's part is asked about each stage, and steering rows sit on their stage" do
    declare_stages
    Harbor::Overview.part(:checks, "Checks") do |stage, _snapshot|
      stage.key == "review" ? [ Harbor::Overview::Item.new(label: "Spelling", mode: "live") ] : []
    end
    Harbor::Overview.steer "hold", want: "Pause it", action: "add `hold`", result: "work stops", stage: "review"
    snapshot = Harbor::Overview::Snapshot.new
    review = snapshot.parts_for(Harbor::Overview.find_stage("review"))
    assert_equal [ "Spelling" ], review[:checks].call.map(&:label)
    assert_equal [ "Pause it" ], review[:steering].call.map(&:want)
    ship = snapshot.parts_for(Harbor::Overview.find_stage("ship"))
    assert_empty ship[:checks].call + ship[:steering].call
  end
end

class HarborOverviewTimingsTest < ActiveSupport::TestCase
  include HarborOverviewSetup

  test "median and p90 duration and cost per task type, over ok runs in the window" do
    [ 1, 2, 3, 4, 10 ].each_with_index { |minutes, i| finished("review", minutes:, cost: i + 1) }
    finished("review", minutes: 90, status: "error")
    finished("review", minutes: 500, started: 40.days.ago)
    finished("rebase", minutes: 5)
    child = finished("review", minutes: 400)
    child.update!(parent_run_id: Harbor::Run.where(task_type: "rebase").pick(:id))

    rows = Harbor::Overview::Timings.by_task_type
    review = rows.fetch("review")
    assert_equal [ 5, 1 ], [ review.runs, review.failed ]
    assert_in_delta 180.0, review.median_seconds, 0.01
    assert_in_delta 456.0, review.p90_seconds, 0.01 # 4m + 0.6 × (10m − 4m)
    assert_in_delta 3.0, review.median_cost, 0.01, "the failed run has no cost, which percentile_cont ignores"
    assert_nil rows.fetch("rebase").median_cost
    assert_equal "3m", Harbor::Overview::Timings.duration_label(review.median_seconds)
    assert_equal [ "1h 30m", "40s", "—" ], [ 5400, 40, nil ].map { |s| Harbor::Overview::Timings.duration_label(s) }
    assert_equal [ "$3.00", "—" ], [ 3, nil ].map { |usd| Harbor::Overview::Timings.cost_label(usd) }
  end
end

class HarborOverviewChangesTest < ActiveSupport::TestCase
  include HarborOverviewSetup

  def rule(kind, key, name, definition)
    Harbor::ReviewRule.new(kind:, key:, name:).tap do |record|
      _, errors = record.save_definition!(definition)
      raise errors.join("; ") if errors.any?
    end
  end

  test "every kind of saved configuration is a source, newest first" do
    declare_stages
    Harbor.config.model_name = ->(model) { model.delete_prefix("claude-").titleize }
    wf = workflow("tidy", "Tidy up", manual([ agent_step("writer") ]))
    wf.versions.update_all(created_at: 8.hours.ago)
    @writer.update_columns(updated_at: 7.hours.ago)
    @planner.update_columns(updated_at: 3.weeks.ago)
    document = Harbor::AgentDocument.create!(agent: @writer, path: "memory.md", body: "Remember.")
    document.update_columns(created_at: 2.days.ago, updated_at: 6.hours.ago)
    setting = Harbor::AgentSetting.create!(key: "shared/house-style.md", body: "Plainly.")
    setting.update_columns(updated_at: 5.hours.ago)
    Harbor::TaskAssignment.update_all(updated_at: 4.hours.ago)
    Harbor::ModelChoice.update_all(updated_at: 3.hours.ago)
    note = Harbor::StageNote.create!(stage_key: "review", body: "Read twice.")
    note.update_columns(updated_at: 2.hours.ago)
    risk = rule("risk", "billing", "Billing", { "label" => "risk: billing", "description" => "Money moves.", "detector" => { "paths" => [ "app/billing/" ] } })
    Harbor::ReviewRuleVersion.update_all(created_at: 1.hour.ago)

    routes = Harbor::Engine.routes.url_helpers
    changes = Harbor::Overview::Changes.recent(since: 1.day.ago)
    assert_equal [
      [ :review_rules, "Risk: Billing v1", "created", routes.review_rule_path(risk) ],
      [ :stage_notes, "Review", "note edited", "/factory#stage-review" ],
      [ :model_choices, "Thinking", "#1 · Sonnet 5 5 · high", routes.edit_model_alias_path(@alias) ],
      [ :task_routing, "review", "→ Wren", routes.agents_path ],
      [ :agent_settings, "house-style.md", "edited", routes.agents_path ],
      [ :agent_documents, "Wren: memory.md", "edited", routes.agent_path(@writer) ],
      [ :agent_prompts, "Wren", "settings or prompt edited", routes.agent_path(@writer) ],
      [ :workflows, "Tidy up v1", "created", routes.workflow_path(wf) ]
    ], changes.map { |change| [ change.source, change.title, change.detail, change.url ] }
    assert_equal [ "Review rules", "Stage note", "Model", "Task routing", "Shared context", "Agent document", "Agent", "Workflow" ],
                 changes.map { |change| Harbor::Overview::Changes.label_for(change.source) }
    assert_includes Harbor::Overview::Changes.recent.map(&:title), "Piper", "with no since, everything recent"
    assert_equal 2, Harbor::Overview::Changes.recent(limit: 2).size
  ensure
    Harbor.config.model_name = ->(model) { model }
  end

  test "this week starts on Monday" do
    travel_to Time.zone.local(2026, 11, 12, 10) do
      Harbor::AgentSetting.create!(key: "shared/new.md", body: "x")
      old = Harbor::AgentSetting.create!(key: "shared/old.md", body: "x")
      old.update_columns(updated_at: Time.zone.local(2026, 11, 8, 23))
      Harbor::Agent.update_all(updated_at: 1.year.ago)
      Harbor::TaskAssignment.update_all(updated_at: 1.year.ago)
      Harbor::ModelChoice.update_all(updated_at: 1.year.ago)
      assert_equal [ "new.md" ], Harbor::Overview::Changes.this_week.map(&:title)
    end
  end

  test "a host adds a source of its own, and replaces one of Harbor's by its name" do
    Harbor::Overview.change_source(:prices, "Price list") do |since:, limit:|
      [ Harbor::Overview::Change.new(at: 1.minute.from_now, source: :prices, title: "Tea", detail: "now 4.00", who: "Sam") ]
    end
    Harbor::Overview.change_source(:agent_prompts, "Agent") { |since:, limit:| [] }
    changes = Harbor::Overview::Changes.recent
    assert_equal [ "Tea", "Sam" ], [ changes.first.title, changes.first.who ]
    assert_equal "Price list", Harbor::Overview::Changes.label_for(:prices)
    assert_empty changes.select { |change| change.source == :agent_prompts }
    assert_equal %i[workflows agent_prompts agent_documents agent_settings task_routing model_choices stage_notes review_rules prices],
                 Harbor::Overview::Changes.sources.keys
    assert_equal "Something else", Harbor::Overview::Changes.label_for(:something_else)
  end

  # A host that also writes agents some other way leaves those out.
  class ImportedAgent < Harbor::Agent
    def self.edited_here = where.not(key: "planner")
  end

  test "which agents count as edited here is the host's agent class's to say" do
    agent_class = Harbor.config.agent_class
    Harbor.config.agent_class = ImportedAgent.name
    assert_equal [ "Wren" ], Harbor::Overview::Changes.recent.select { |change| change.source == :agent_prompts }.map(&:title)
  ensure
    Harbor.config.agent_class = agent_class
  end
end

class HarborOverviewSummaryTest < ActiveSupport::TestCase
  include HarborOverviewSetup

  def tiles = Harbor::Overview::Summary.new.tiles.index_by(&:key)

  test "one number for each thing Harbor keeps, from the records" do
    finished("review", minutes: 3, cost: 1.25)
    finished("review", minutes: 3, status: "error", cost: 0.5)
    finished("review", minutes: 3, cost: 9, started: 40.days.ago)
    Harbor::Run.create!(task_type: "review", status: "running")
    @planner.update!(enabled: false)
    workflow("tidy", "Tidy up", manual([ agent_step("writer") ]))
    workflow("dry", "Dry", manual([ agent_step("writer") ]), mode: "dry_run")
    automation("sweep", "Sweep")
    automation("off", "Off", enabled: false)
    Harbor::Runtime.create!(key: "laptop", name: "Laptop", backend: "orca", config: { "repo" => "name:app" })
    scorer = Harbor::Scorer.create!(name: "Ran the tests", judge_instructions: "Did it?", model_alias: @alias, sample_rate: 0, pass_threshold: 1.0,
                                    classifications: [ { "label" => "pass", "score" => 1.0 }, { "label" => "fail", "score" => 0.0 } ])
    runs = Harbor::Run.where(status: %w[ok error]).order(:id).to_a
    Harbor::ScorerResult.create!(scorer:, run: runs[0], status: "ok", passed: true, classification: "pass", score: 1, scored_at: 1.day.ago)
    Harbor::ScorerResult.create!(scorer:, run: runs[1], status: "ok", passed: false, classification: "fail", score: 0, scored_at: 1.day.ago)
    Harbor::ScorerResult.create!(scorer:, run: runs[2], status: "ok", passed: false, classification: "fail", score: 0, scored_at: 40.days.ago)
    Harbor::ReviewRound.create!(repo: "acme/shop", pr_number: 5, head_sha: "abcdef1234", phase: "published", finished_at: 1.hour.ago)
    Harbor::ReviewRound.create!(repo: "acme/shop", pr_number: 5, head_sha: "abcdef1235", round: 2)

    assert_equal %i[runs spend agents workflows automations runtimes scorers proposals reviews], tiles.keys
    shown = tiles.transform_values { |tile| [ tile.label, tile.value, tile.note ] }
    assert_equal [ "Runs", 3, "1 failed · 1 under way now" ], shown[:runs]
    assert_equal [ "Spend", "$1.75", "2 runs with a cost" ], shown[:spend]
    assert_equal [ "Agents", 1, "1 switched off" ], shown[:agents]
    assert_equal [ "Workflows", 1, "live · 1 in dry run · 0 off" ], shown[:workflows]
    assert_equal [ "Automations", 1, "on · 1 off" ], shown[:automations]
    assert_equal [ "Runtimes", 1, "on · 0 off" ], shown[:runtimes]
    assert_equal [ "Scorers", "50%", "of 2 judged runs passed" ], shown[:scorers]
    assert_equal [ "Proposals", 0, "waiting for a person" ], shown[:proposals]
    assert_equal [ "Review rounds", 2, "on 1 pull request" ], shown[:reviews]
    assert_equal "/factory/runs", tiles[:runs].url
    assert_equal "/factory/velocity?range=30d&tab=spending", tiles[:spend].url
  end

  test "with nothing recorded the tiles say so, and a tile whose page is switched off is left out" do
    assert_equal [ 0, "$0.00", "—" ], tiles.values_at(:runs, :spend, :scorers).map(&:value)
    Harbor::Setting.set!(:page_reviews, "false")
    Harbor::Setting.set!(:page_velocity, "false")
    assert_equal %i[runs agents workflows automations runtimes scorers proposals], tiles.keys
  end

  test "a host's tile sits after the one it names, or at the end" do
    Harbor::Overview.tile(:tickets, label: "Tickets", after: :runs) { |since| { value: 12, note: "since #{since.to_date}", url: "/tickets" } }
    Harbor::Overview.tile(:orders, label: "Orders") { |_since| { value: "7" } }
    assert_equal %i[runs tickets spend], tiles.keys.first(3)
    assert_equal :orders, tiles.keys.last
    assert_equal [ "Tickets", 12, "since #{30.days.ago.to_date}", "/tickets" ], tiles[:tickets].then { |t| [ t.label, t.value, t.note, t.url ] }
  end
end

class HarborStageNoteTest < ActiveSupport::TestCase
  include HarborOverviewSetup

  test "a note is for a stage that exists, one each" do
    declare_stages
    assert Harbor::StageNote.new(stage_key: "review", body: "Read twice.").save
    assert_equal [ "Stage key has already been taken" ], Harbor::StageNote.create(stage_key: "review").errors.full_messages
    assert_equal [ "Stage key is not a stage of Overview" ], Harbor::StageNote.create(stage_key: "nope").errors.full_messages
    assert_equal %w[review], Harbor::StageNote.for_stages.keys
    assert_nil Harbor::StageNote.first.editor_label, "no user class, so nobody is named"
  end

  test "every save is handed to the host to keep, as markdown with what it is on top" do
    exported = []
    Harbor.config.export = ->(path, body) { exported << [ path, body ] }
    travel_to Time.utc(2026, 11, 12, 17) do
      note = Harbor::StageNote.create!(stage_key: "work", body: "  Everything happens here.\n\n")
      assert_equal [ [ "factory/notes/work.md", "---\nstage: work\nupdated_at: '2026-11-12T17:00:00Z'\n---\n\nEverything happens here.\n" ] ], exported
      note.update!(body: "Less happens here.")
      assert_equal 2, exported.size
    end
  end

  test "a failing export is logged and the note is still saved" do
    Harbor.config.export = ->(*) { raise "disk full" }
    assert Harbor::StageNote.create!(stage_key: "work", body: "Kept.").persisted?
  end
end
