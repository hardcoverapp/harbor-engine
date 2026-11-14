require "test_helper"

# The Workflows pages: the list, a workflow's page, the builder, the
# reference, and a run's page. What a site with no code of its own gets, and
# each place a host can add to or reword.
class HarborWorkflowPagesTest < ActionDispatch::IntegrationTest
  include HarborWorkflows

  HOST_VIEWS = File.expand_path("fixtures/host_views", __dir__)
  CONTROLLERS = [ Harbor::WorkflowsController, Harbor::WorkflowRunsController ].freeze

  setup do
    [ Harbor::TaskAssignment, Harbor::AgentDocument, Harbor::Agent ].each(&:delete_all)
    @view_paths = CONTROLLERS.index_with(&:view_paths)
    post "/login", params: { name: "Sam Settings" }
  end

  teardown { @view_paths.each { |controller, paths| controller.view_paths = paths } }

  # What a host does: a views folder of its own, looked in before Harbor's.
  def host_views(name) = CONTROLLERS.each { |controller| controller.prepend_view_path(File.join(HOST_VIEWS, name)) }

  def note(key, message) = { "key" => key, "type" => "action", "action" => "note", "message" => message }

  def definition(*steps) = { "triggers" => [ { "kind" => "manual" } ], "steps" => steps }

  def builder(mode) = css_select("[data-controller='harbor--workflow-builder'][data-harbor--workflow-builder-mode-value='#{mode}']").first

  def catalog(element) = JSON.parse(element["data-harbor--workflow-builder-catalog-value"])

  def advance = perform_enqueued_jobs(only: Harbor::Workflows::AdvanceJob)

  def current_page = css_select("[data-harbor-nav] a[aria-current=page]").map { |a| a.text.strip }

  # --- a site with no code of its own ---

  test "a site with no host code builds a workflow on the page, starts it, and watches its run finish" do
    get harbor.workflows_path
    assert_response :success
    assert_select "title", text: "Workflows"
    assert_equal [ "Workflows" ], current_page
    assert_select "p", text: "No workflows yet."
    assert_select "a[href=?]", harbor.new_workflow_path, text: "New workflow"

    # The builder opens on a workflow that can be saved as it is.
    get harbor.new_workflow_path
    assert_response :success
    form = builder("edit")
    assert_equal "workflow-form", form["id"]
    assert_equal harbor.workflows_path, form["action"]
    started_as = JSON.parse(css_select("textarea#workflow_definition").first.text)
    assert_equal [ "manual" ], started_as["triggers"].map { |t| t["kind"] }
    assert_select ".wf-toolbar button[type=submit]", text: "Create workflow"
    palette = catalog(form)
    assert_equal [ "Run an agent", "Review / verify", "Note", "Filter", "Router", "Repeat until", "Approval", "Run workflow" ],
                 palette["modules"].map { |m| m["label"] }
    assert_equal [ "Run by hand" ], palette["triggers"].map { |t| t["label"] }
    assert_equal harbor.reference_workflows_path, palette["reference_url"]

    # What the builder would send: the definition as JSON, a name and a key.
    built = definition(note("hello", "Hello from {{trigger.sender}}, with {{input.name}}"),
                       { "key" => "ok", "type" => "approval", "name" => "Go on?", "prompt" => "Go on?" },
                       note("after", "{{steps.ok.decision}}"))
    post harbor.workflows_path, params: { workflow: { name: "Greeter", key: "greeter", description: "Says hello.", definition: built.to_json } }
    workflow = Harbor::Workflow.find_by!(key: "greeter")
    assert_redirected_to harbor.workflow_path(workflow)
    assert_equal [ "off", 1, built ], [ workflow.mode, workflow.current_version.number, workflow.current_version.definition ]
    follow_redirect!
    assert_select "[data-notice]", text: /Created Greeter \(version 1\)/
    assert_select "h1", text: "Greeter"
    assert_equal built, JSON.parse(builder("view")["data-harbor--workflow-builder-definition-value"])
    assert_select "details #node-ok", text: /Approval\s+Go on\?/
    assert_select "details #node-hello p", text: /note · Hello from/

    # Live, with workflows switched on, and started by hand.
    patch harbor.mode_workflow_path(workflow, mode: "live")
    assert_equal "live", workflow.reload.mode
    post harbor.run_workflow_path(workflow), params: { input: '{"name": "tea"}' }
    run = workflow.workflow_runs.sole
    assert_redirected_to harbor.workflow_run_path(run)
    assert_equal [ "live", "manual", { "kind" => "manual", "sender" => "Sam Settings" }, { "name" => "tea" } ],
                 [ run.mode, run.trigger_kind, run.context["trigger"], run.context["input"] ]

    # It runs to the approval and waits there, shown on its page.
    advance
    get harbor.workflow_run_path(run)
    assert_response :success
    assert_equal [ "Workflows" ], current_page
    assert_select "h1", text: "Run ##{run.id}"
    assert_select "#workflow-run-header .pill", text: "waiting"
    assert_select "[data-controller='harbor--poll'][data-harbor--poll-interval-value='5']", count: 1, message: "the page refreshes while the run is live"
    statuses = JSON.parse(builder("run")["data-harbor--workflow-builder-statuses-value"])
    assert_equal %w[ok waiting], statuses.values_at("hello", "ok").map { |s| s["status"] }
    assert_match %r{/factory/workflow_runs/#{run.id}\?step=\d+#step}, statuses.dig("hello", "url")
    assert_select "#step[data-run-panel=step] .wf-panel-title", text: "Go on?", message: "it opens on the step in progress"
    assert_select "#step form[action=?]", harbor.decide_workflow_run_path(run, step_run_id: step_of(run, "ok").id) do
      assert_select "button[name=decision][value=approve]", text: "Approve"
    end

    # Approved: the run finishes, and the page says so.
    post harbor.decide_workflow_run_path(run, step_run_id: step_of(run, "ok").id), params: { decision: "approve", note: "yes" }
    assert_redirected_to harbor.workflow_run_path(run)
    advance
    get harbor.workflow_run_path(run, panel: "steps")
    assert_select "#workflow-run-header .pill", text: "succeeded"
    assert_select "[data-controller='harbor--poll']", count: 0
    assert_select "#step #node-hello .pill", text: "ok"
    assert_select "form[action=?]", harbor.rerun_workflow_run_path(run), count: 1
    hello = step_of(run, "hello")
    assert_equal "Hello from Sam Settings, with tea", hello.output["message"]
    assert_equal [ "approved", "Sam Settings", "yes" ], step_of(run, "ok").output.values_at("decision", "by", "note")

    get harbor.workflow_run_path(run, step: hello.id)
    assert_select "#step details pre", text: /Hello from Sam Settings, with tea/

    # And it is on the list, the workflow's own page and the recent runs.
    get harbor.workflows_path
    assert_select "#workflow-greeter" do
      assert_select "a[href=?]", harbor.workflow_path(workflow), text: "Greeter"
      assert_select ".pill", text: "live"
      assert_select "li", text: "Run by hand"
      assert_select "[data-run='#{run.id}'][data-run-state=finished] a[href=?]", harbor.workflow_run_path(run)
    end
    get harbor.workflow_runs_path
    assert_select "a[href=?]", harbor.workflow_run_path(run), text: "##{run.id}"
  end

  # --- the list ---

  test "the list says when workflows are switched off, and shows each workflow's runs" do
    Harbor::Setting.set!(:workflows_enabled, false)
    wf = workflow(definition(note("hello", "hi")), key: "greeter")
    active = Harbor::WorkflowRun.create!(workflow: wf, workflow_version: wf.current_version, status: "waiting", mode: "dry_run", trigger_kind: "manual",
                                         pr_number: 12, started_at: 2.minutes.ago)
    get harbor.workflows_path
    assert_select "[role=status]", text: /Workflows are switched off\..*nothing starts on its own/m
    assert_select "[role=status] a[href=?]", harbor.settings_path
    assert_select "[data-run='#{active.id}'][data-run-state=active]", text: /Waiting on PR #12\s+dry run/
    assert_select "[data-controller='harbor--poll']", count: 1
    assert_select "nav[data-tabs=workflows] a[aria-current=page]", text: "Workflows"

    get harbor.workflow_runs_path(workflow: "greeter")
    assert_select "[data-runs-filter] a[href=?]", harbor.workflow_path(wf), text: wf.name
    assert_select "nav[data-tabs=workflows] a[aria-current=page]", text: "Recent runs"
  end

  # --- creating and editing ---

  test "bad JSON, bad steps and a bad key re-render the builder with the reasons" do
    post harbor.workflows_path, params: { workflow: { name: "Nudge", key: "nudge", definition: "{ nope" } }
    assert_response :unprocessable_entity
    assert_select "[role=alert] li", text: /Not valid JSON/
    assert_equal [ "Not valid JSON" ], JSON.parse(builder("edit")["data-harbor--workflow-builder-errors-value"]).map { |e| e[0, 14] }

    bad = { triggers: [ { kind: "manual" } ], steps: [ { key: "loop", type: "loop", steps: [] } ] }.to_json
    post harbor.workflows_path, params: { workflow: { name: "Nudge", key: "nudge", definition: bad } }
    assert_response :unprocessable_entity
    assert_select "[role=alert] li", text: /a loop needs max_iterations/
    assert_equal JSON.parse(bad), JSON.parse(css_select("textarea#workflow_definition").first.text), "what was built is still there"

    post harbor.workflows_path, params: { workflow: { name: "Nudge", key: "Not A Key", definition: definition(note("hi", "hi")).to_json } }
    assert_response :unprocessable_entity
    assert_select "[role=alert] li", text: "Key is invalid"
    assert_equal 0, Harbor::Workflow.count
  end

  test "saving makes a version only when the steps changed, and the key never changes" do
    wf = workflow(definition(note("hi", "hi")), key: "nudge", mode: "off")
    get harbor.edit_workflow_path(wf)
    assert_response :success
    assert_equal wf.current_version.definition, JSON.parse(css_select("textarea#workflow_definition").first.text)
    assert_select ".wf-toolbar button[type=submit]", text: "Save"
    assert_select "input[name='workflow[key]']", count: 0
    assert_select "[data-harbor--workflow-builder-target=details] textarea[name='workflow[description]']"
    assert_includes catalog(builder("edit"))["workflows"], { "key" => "nudge", "name" => wf.name }

    patch harbor.workflow_path(wf), params: { workflow: { name: "Nudge 2", key: "renamed", definition: wf.current_version.definition.to_json } }
    assert_redirected_to harbor.workflow_path(wf)
    assert_equal [ "Nudge 2", "nudge", 1 ], [ wf.reload.name, wf.key, wf.current_version.number ]
    assert_equal "Saved Nudge 2; the steps didn't change.", flash[:notice]

    patch harbor.workflow_path(wf), params: { workflow: { name: "Nudge 2", definition: definition(note("hi", "hello")).to_json } }
    assert_equal 2, wf.reload.current_version.number
    assert_equal "Saved Nudge 2 as version 2.", flash[:notice]

    get harbor.workflow_path(wf)
    assert_equal %w[v2 v1], css_select("ol li span.font-mono").map(&:text)
  end

  test "the mode is switched from the workflow's page, and live says when workflows are off" do
    Harbor::Setting.set!(:workflows_enabled, false)
    wf = workflow(definition(note("hi", "hi")), mode: "off")
    get harbor.workflow_path(wf)
    assert_equal [ "off", "dry run", "live" ], css_select("[role=group] button").map { |b| b.text.strip }
    assert_select "[role=group] button[aria-pressed=true]", text: "off"

    patch harbor.mode_workflow_path(wf, mode: "live")
    assert_equal "live", wf.reload.mode
    assert_match "Workflows are switched off in Settings, so it still only dry-runs.", flash[:notice]
    patch harbor.mode_workflow_path(wf, mode: "sideways")
    assert_equal [ "live", "Unknown mode" ], [ wf.reload.mode, flash[:alert] ]
  end

  test "the builder offers the enabled agents and the declared task types" do
    Harbor::TaskTypes.reset!
    Harbor::TaskTypes.declare "review"
    Harbor::Agent.create!(key: "writer", name: "Wren")
    Harbor::Agent.create!(key: "retired", enabled: false)
    get harbor.new_workflow_path
    offered = catalog(builder("edit"))
    assert_equal [ { "key" => "writer", "name" => "Wren" } ], offered["agents"]
    assert_equal %w[review], offered["task_types"]
  ensure
    Harbor::TaskTypes.reset!
  end

  # --- starting a run by hand ---

  test "a run started by hand is a dry run unless the workflow is live; bad input says so" do
    wf = workflow(definition(note("hi", "hi")), mode: "dry_run")
    get harbor.workflow_path(wf)
    assert_select "form[action=?]", harbor.run_workflow_path(wf) do
      assert_select "textarea[name=input]"
      assert_select "input[type=checkbox][name=dry_run][checked]"
    end
    post harbor.run_workflow_path(wf)
    run = wf.workflow_runs.sole
    assert_equal "dry_run", run.mode
    advance
    assert_equal [ "succeeded", "skipped" ], [ run.reload.status, step_of(run, "hi").status ]
    follow_redirect!
    assert_select "#workflow-run-header .pill", text: "dry run"

    post harbor.run_workflow_path(wf), params: { input: "{ nope" }
    assert_redirected_to harbor.workflow_path(wf)
    assert_match "Input isn't valid JSON", flash[:alert]
    post harbor.run_workflow_path(wf), params: { input: "[1]" }
    assert_match "Input isn't valid JSON: the input must be an object", flash[:alert]
    assert_equal 1, wf.workflow_runs.count
  end

  test "a host says what a run started by hand is given, and what it is about" do
    Harbor.config.workflow_manual_start = lambda do |params, user, input|
      [ { "kind" => "manual", "ticket" => params[:ticket].to_i, "sender" => user.email }, input.merge("ticket" => params[:ticket].to_i) ]
    end
    Harbor.config.workflow_subject = ->(trigger, _input) { { repo: "desk", issue_number: trigger["ticket"] } }
    wf = workflow(definition({ "key" => "ok", "type" => "approval" }))
    host_views "overrides"
    get harbor.workflow_path(wf)
    assert_select "form[action=?] [data-host-run-fields] input[name=ticket]", harbor.run_workflow_path(wf)
    assert_select "form[action=?] textarea[name=input]", harbor.run_workflow_path(wf), count: 0, message: "the host's fields stand in for Harbor's"

    post harbor.run_workflow_path(wf), params: { ticket: "41" }
    run = wf.workflow_runs.sole
    assert_equal [ 41, "sam-settings@example.com", { "ticket" => 41 }, 41, "desk" ],
                 [ run.context.dig("trigger", "ticket"), run.context.dig("trigger", "sender"), run.context["input"], run.issue_number, run.github_repo ]
    post harbor.run_workflow_path(wf), params: { ticket: "41" }
    assert_redirected_to harbor.workflow_path(wf)
    assert_match "already running", flash[:alert]

    get harbor.workflow_run_path(run)
    assert_select "[data-run-summary]", text: /issue #41/
    assert_select "[data-run-summary] a", text: "issue #41", count: 0, message: "Harbor doesn't know where the subject lives"
  end

  # --- a run's page ---

  test "a run's page: its summary, its panels, cancel and run again" do
    wf = workflow(definition(note("hello", "hi"), { "key" => "ok", "type" => "approval" }), key: "greeter")
    post harbor.run_workflow_path(wf), params: { dry_run: "0" }
    run = wf.workflow_runs.sole
    advance
    get harbor.workflow_run_path(run, step: "none")
    assert_select "nav[data-breadcrumbs] a", text: wf.name
    assert_select "[data-run-summary]", text: /started by manual\s+·\s+version 1/
    assert_select "#step", count: 0, message: "step=none closes the panel"
    assert_select ".wf-toolbar a[href=?]", harbor.workflow_run_path(run, panel: "steps")
    assert_select ".wf-toolbar a[href=?]", harbor.workflow_run_path(run, panel: "context")

    get harbor.workflow_run_path(run, panel: "context")
    assert_select "#step[data-run-panel=context] pre", text: /"sender": "Sam Settings"/

    post harbor.cancel_workflow_run_path(run)
    assert_redirected_to harbor.workflow_run_path(run)
    advance
    assert_equal [ "canceled", "canceled by Sam Settings" ], [ run.reload.status, step_of(run, "ok").error ]
    post harbor.decide_workflow_run_path(run, step_run_id: step_of(run, "ok").id), params: { decision: "approve" }
    assert_equal "That step isn't waiting for a decision.", flash[:alert]

    post harbor.rerun_workflow_run_path(run)
    again = wf.workflow_runs.order(:id).last
    assert_redirected_to harbor.workflow_run_path(again)
    assert_equal [ "Started again.", "manual", run.context["trigger"] ], [ flash[:notice], again.trigger_kind, again.context["trigger"] ]
  end

  test "an agent step's panel shows its Run, its cost and the end of its log" do
    logs = Dir.mktmpdir("harbor-logs")
    location = Harbor.config.log_location
    Harbor.config.log_location = ->(path) { File.join(logs, path) }
    wf = workflow(definition({ "key" => "work", "type" => "agent", "agent" => "writer", "prompt" => "Tidy" }))
    workflow_run = Harbor::WorkflowRun.create!(workflow: wf, workflow_version: wf.current_version, status: "running", mode: "live", trigger_kind: "manual")
    run = Harbor::Run.create!(skill: "workflow.#{wf.key}.work", agent_key: "writer", status: "running", workflow_run_id: workflow_run.id,
                              workflow_step_key: "work", cost_usd_actual: 0.5, started_at: Time.current)
    step = workflow_run.step_runs.create!(step_key: "work", step_type: "agent", status: "running", run:, input: { "prompt" => "Tidy" })
    Harbor::LiveLog.append(run.live_log_path, "reading the shelf\n")

    get harbor.workflow_run_path(workflow_run)
    assert_select "#step [data-step-status]" do
      assert_select "a[href=?]", harbor.run_path(run), text: "Run ##{run.id}"
      assert_select "span", text: "$0.5000"
    end
    assert_select "#step-log pre.wf-log[data-controller='harbor--log-follow']", text: /reading the shelf/
    assert_select "#step-log .pill", text: "streaming"
    assert_select "details#step-went-in-#{step.id}[data-controller='harbor--details']"

    get harbor.run_path(run)
    assert_select "#run-header a[href=?]", harbor.workflow_run_path(workflow_run)
  ensure
    Harbor.config.log_location = location
    FileUtils.remove_entry(logs) if logs
  end

  # --- the reference ---

  test "the reference page prints what is registered: triggers, gates, operators, data and modules" do
    get harbor.reference_workflows_path
    assert_response :success
    assert_select "#triggers h3", text: "Run by hand"
    assert_equal [ "Trigger filter", "Filter filter", "Router choice", "Repeat until loop", "Approval approval", "If it fails" ],
                 css_select("#gates tbody th").map { |th| th.text.squish }
    assert_select "#operators li", count: Harbor::Workflows::Condition::OPS.size
    assert_select "#data code", text: "sender"
    assert_select "#data h3", text: "Settings", count: 0, message: "no settings are registered"
    assert_select "#data p", text: /Inside a Wait's filter/, count: 0
    assert_equal [ "Agents", "Harbor", "Flow control" ], css_select("#modules h3").map(&:text)
    assert_select "#modules h4", text: "Run workflow"

    register_say(group: "Desk")
    Harbor::Workflows.register_setting "channel", label: "Channel", kind: "text", help: "Where it posts."
    Harbor::Workflows.register_data :trigger, "queue", "string", "the ticket's queue"
    get harbor.reference_workflows_path
    assert_select "#modules h3", text: "Desk"
    assert_select "#modules code", text: "action · say"
    assert_select "#data li", text: /channel\s+Where it posts\./
    assert_select "#data code", text: "queue"
  end

  # --- what a host adds ---

  test "a host's flows a live workflow can take over are offered in the builder and shown on the list" do
    get harbor.new_workflow_path
    assert_select "input[name='workflow[claims][]']", count: 0, message: "a site with no such flows has no such box"

    Harbor::Workflows.register_claim "triage", "New tickets → TriageJob"
    get harbor.new_workflow_path
    assert_select "fieldset label", text: /triage\s+New tickets → TriageJob/
    post harbor.workflows_path, params: { workflow: { name: "Triage", key: "triage", claims: [ "", "triage" ], definition: definition(note("hi", "hi")).to_json } }
    assert_equal %w[triage], Harbor::Workflow.find_by!(key: "triage").claims

    get harbor.workflows_path
    assert_select "#workflow-triage .pill[title='New tickets → TriageJob']", text: "claims triage"
    post harbor.workflows_path, params: { workflow: { name: "Other", key: "other", claims: [ "everything" ], definition: definition(note("hi", "hi")).to_json } }
    assert_response :unprocessable_entity
    assert_select "[role=alert] li", text: /can't be claimed: everything/
  end

  test "a host that can turn a delivery into trigger data gets Test with an event" do
    wf = workflow({ "triggers" => [ { "kind" => "ticket", "queue" => "support" } ], "steps" => [ note("hi", "{{trigger.queue}}") ] }.tap do
      Harbor::Workflows.register_trigger "ticket", label: "Ticket", summary: ->(t) { "Ticket in #{t['queue']}" },
                                                   matches: ->(trigger, event, data) { event.event == "ticket" && data["queue"] == trigger["queue"] }
    end)
    event = Harbor::WebhookEvent.create!(provider: "desk", event: "ticket", action: "opened", delivery_id: SecureRandom.uuid,
                                         status: "received", received_at: Time.current, payload: { "queue" => "support" })
    other = Harbor::WebhookEvent.create!(provider: "desk", event: "ticket", action: "opened", delivery_id: SecureRandom.uuid,
                                         status: "received", received_at: Time.current, payload: { "queue" => "sales" })
    get harbor.workflow_path(wf)
    assert_select "#test", count: 0, message: "without the hook there is nothing to test with"
    post harbor.test_workflow_path(wf), params: { webhook_event_id: event.id }
    assert_response :not_found

    Harbor.config.workflow_event_data = ->(delivery) { { "kind" => "ticket", "queue" => delivery.payload["queue"] } }
    get harbor.workflow_path(wf)
    assert_select "li", text: "Ticket in support"
    assert_select "#test select[name=webhook_event_id] option", count: 2

    post harbor.test_workflow_path(wf), params: { webhook_event_id: event.id, start: "0" }
    assert_response :success
    assert_select "#test p.text-ink-green", text: "Trigger 1 matches."
    assert_select "#test pre", text: /"queue": "support"/
    post harbor.test_workflow_path(wf), params: { webhook_event_id: other.id, start: "0" }
    assert_select "#test p.text-ink-red", text: "No trigger matches this event."
    assert_equal 0, wf.workflow_runs.count

    post harbor.test_workflow_path(wf), params: { webhook_event_id: event.id, start: "1" }
    run = wf.workflow_runs.sole
    assert_redirected_to harbor.workflow_run_path(run)
    assert_equal [ "dry_run", "desk", event.id, "support" ], [ run.mode, run.trigger_kind, run.webhook_event_id, run.context.dig("trigger", "queue") ]
    get harbor.workflow_run_path(run)
    assert_select "[data-run-summary]", text: /started by desk \(ticket\.opened\)/
  end

  test "a host adds to the pages with partials of its own" do
    wf = workflow(definition(note("hi", "hi")))
    get harbor.workflows_path
    assert_select "[data-host-action]", count: 0

    host_views "extras"
    get harbor.workflows_path
    assert_select "header [data-host-action]", text: "Load our starters"
    get harbor.edit_workflow_path(wf)
    assert_select "[data-harbor--workflow-builder-target=details] [data-host-field] input[name='workflow[owner]']"
    get harbor.workflow_path(wf)
    assert_select "[data-host-note]", text: "Also kept in the archive as workflows/#{wf.key}.json."
    get harbor.reference_workflows_path
    assert_select "#triggers [data-host-reference]", text: "Tickets come from the desk."
  end

  test "a host rewords the list's introduction, its empty state and the switched-off notice" do
    Harbor::Setting.set!(:workflows_enabled, false)
    host_views "overrides"
    get harbor.workflows_path
    assert_select "header [data-host-intro]", text: "Workflows move tickets through the desk."
    assert_select "[role=status] [data-host-off]", text: "The desk's workflows are off."
    assert_select "[data-host-empty]", text: /Load the desk's starters/
    assert_no_match "A trigger starts a chain of steps", response.body
  end

  test "a host's starter is what a new workflow opens on" do
    Harbor.config.workflow_starter = -> { definition(note("first", "from the desk")) }
    get harbor.new_workflow_path
    assert_equal "from the desk", JSON.parse(css_select("textarea#workflow_definition").first.text).dig("steps", 0, "message")
  end

  test "with a user class, a version names who saved it" do
    # The dummy host's user is not a record, so the association is never
    # declared there; a version then shows its date alone.
    wf = workflow(definition(note("hi", "hi")))
    get harbor.workflow_path(wf)
    assert_select "ol li span.meta", text: /\A[^·]+\z/
    assert_nil Harbor.config.user_class
  end

  # --- switching the page off ---

  test "switched off, every Workflows page answers as not found and leaves the menu" do
    wf = workflow(definition(note("hi", "hi")))
    run = start_workflow(wf)
    Harbor::Setting.set!(Harbor::Pages.setting_key(:workflows), false)
    [ harbor.workflows_path, harbor.workflow_path(wf), harbor.new_workflow_path, harbor.reference_workflows_path,
      harbor.workflow_runs_path, harbor.workflow_run_path(run) ].each do |path|
      get path
      assert_response :not_found, path
    end
    post harbor.run_workflow_path(wf)
    assert_response :not_found
    get harbor.runs_path
    assert_select "[data-harbor-nav] a", text: "Workflows", count: 0
  end

  test "someone who isn't logged in is sent to log in" do
    delete "/logout"
    get harbor.workflows_path
    assert_redirected_to "/login"
  end
end
