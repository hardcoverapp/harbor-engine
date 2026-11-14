require "test_helper"

# The Runs list and a run's own page: what a site with no code of its own
# gets, and each place a host can add to or replace.
class HarborRunsPagesTest < ActionDispatch::IntegrationTest
  include HarborAgentSessions

  # A host's run class: a filter of its own on the list, and a name of its
  # own for one kind of run.
  class HostRun < Harbor::Run
    def self.for_page(filters = {})
      filters[:skill].present? ? super.where(skill: filters[:skill]) : super
    end

    def label = skill == "writer.tidy" ? "Tidy the shelves" : super
  end

  HOST_VIEWS = File.expand_path("fixtures/host_views", __dir__)

  setup do
    @run_stop = Harbor.config.run_stop
    @run_class = Harbor.config.run_class
    @view_paths = Harbor::RunsController.view_paths
    post "/login", params: { name: "Sam Settings" }
  end

  teardown do
    Harbor.config.run_stop = @run_stop
    Harbor.config.run_class = @run_class
    Harbor::RunsController.view_paths = @view_paths
  end

  def finished(**attrs)
    Harbor::Run.create!({ skill: "nightly-report", status: "ok", started_at: 10.minutes.ago, ended_at: 4.minutes.ago }.merge(attrs))
  end

  # What a host does: a views folder of its own, looked in before Harbor's.
  def host_views(name) = Harbor::RunsController.prepend_view_path(File.join(HOST_VIEWS, name))

  # --- the list ---

  test "the list shows runs newest first, each with its name, status, how long it took and when" do
    old = finished(started_at: 3.hours.ago, ended_at: 2.hours.ago)
    recent = finished(skill: "writer.fix", agent_key: "writer", status: "error")
    get harbor.runs_path
    assert_response :success
    assert_equal [ recent.id, old.id ], css_select("li[data-run]").map { |li| li["data-run"].to_i }
    assert_select "li[data-run='#{recent.id}']" do
      assert_select "a[href=?]", harbor.run_path(recent), text: "writer.fix", count: 1
      assert_select "[data-status=error]", text: "error", count: 1
      assert_select "[data-run-meta]", text: /Writer/
      assert_select "[data-run-meta]", text: /6m · less than a minute ago/
    end
    assert_select "li[data-run='#{old.id}'] [data-run-meta]", text: /1h 0m/
    assert_select "[data-harbor-nav] a[aria-current=page]", text: "Runs", count: 1
  end

  test "a row is two lines on a phone: the name with its status, then a line that wraps" do
    run = finished(skill: "a.very.long.skill.name.that.would.not.fit.on.a.narrow.screen")
    loader = finished(loader: "catalog-import")
    get harbor.runs_path
    assert_select "li[data-run='#{run.id}']" do
      assert_select "a[href=?][class*='overflow-wrap:anywhere']", harbor.run_path(run), count: 1
      assert_select "[data-run-meta].flex-wrap", count: 1
      assert_select "[data-run-meta] .font-mono", count: 0, message: "the skill isn't repeated when it is the label"
      assert_select "[data-run-meta] .whitespace-nowrap", text: /ago/
    end
    assert_select "li[data-run='#{loader.id}'] a", text: "Catalog Import"
  end

  test "a skill that isn't the run's name is shown beside it" do
    Harbor.config.run_class = "HarborRunsPagesTest::HostRun"
    run = finished(skill: "writer.tidy")
    get harbor.runs_path
    assert_select "li[data-run='#{run.id}'] a", text: "Tidy the shelves"
    assert_select "li[data-run='#{run.id}'] [data-run-meta] .font-mono", text: "writer.tidy"
  end

  test "delegated runs sit under their parent, which shows the total" do
    parent = finished(skill: "writer.fix", cost_usd_actual: 1.84)
    child = finished(skill: "writer.look-up", agent_key: "writer", parent_run_id: parent.id, cost_usd_estimate: 0.21)
    get harbor.runs_path
    assert_select "li[data-run='#{parent.id}'] ul a[href=?]", harbor.run_path(child), text: "writer.look-up"
    assert_select "li[data-run='#{parent.id}'] ul [data-status=ok]", count: 1
    assert_select "li[data-run='#{parent.id}'] ul", text: /Writer.*\$0\.21/m
    assert_select "li[data-run='#{child.id}']", count: 0
    assert_select "li[data-run='#{parent.id}'] [data-run-meta]", text: /\$1\.84 total/
  end

  test "an empty list says so" do
    get harbor.runs_path
    assert_response :success
    assert_select "p", text: "No runs yet."
    assert_select "li[data-run]", count: 0
  end

  test "a host's run class decides what the list holds, from the page's query" do
    Harbor.config.run_class = "HarborRunsPagesTest::HostRun"
    wanted = finished(skill: "writer.fix")
    other = finished
    get harbor.runs_path
    assert_select "li[data-run]", count: 2
    get harbor.runs_path(skill: "writer.fix")
    assert_equal [ wanted.id ], css_select("li[data-run]").map { |li| li["data-run"].to_i }, "#{other.id} is left out"
  end

  # --- a run's page ---

  test "a run's page says what ran, how it went, who ran it, when, and what it cost" do
    run = finished(skill: "writer.fix", agent_key: "writer", model: "claude-sonnet-5-5", effort: "medium", session_id: "sess-12345678-abcd",
                   cost_usd_actual: 0.4321, input_tokens: 1200, output_tokens: 300, input: { "ask" => "fix it" }, output: { "text" => "done" })
    get harbor.run_path(run)
    assert_response :success
    assert_select "title", text: "writer.fix · Run ##{run.id}"
    assert_select "#run-header" do
      assert_select "a[href=?]", harbor.runs_path, text: "All runs"
      assert_select "h1", text: /writer\.fix/
      assert_select "h1 [data-status=ok]", count: 1
      assert_select "p", text: /writer\.fix\s+·\s+started .*·\s+360\.0s/m
      assert_select "[data-run-facts]", text: /Writer\s+·\s+claude-sonnet-5-5 medium\s+·\s+\$0\.4321\s+·\s+1k in \/ 300 out\s+·\s+session sess-123/
    end
    assert_select "#run-payloads pre", text: /"ask": "fix it"/
    assert_select "#run-payloads pre", text: /"text": "done"/
    assert_select "#run-error", count: 0
    assert_select "[data-controller='harbor--poll']", count: 0, message: "a finished run's page doesn't refresh itself"
    assert_select "[data-harbor-nav] a[aria-current=page]", text: "Runs", count: 1
  end

  test "the details say where it ran, on what model, with what command, what started it and when" do
    run = finished(skill: "writer.fix", agent_key: "writer", task_type: "fix", runtime_id: @runtime.id, runner_name: "term-7",
                   model: "claude-sonnet-5-5", effort: "medium", command: "claude -p --model claude-sonnet-5-5 --verbose",
                   trigger_source: "webhook", trigger: "push", trigger_ref: "main")
    get harbor.run_path(run)
    assert_select "#run-details[data-run-details]" do
      assert_select "dd", text: /skill\s+writer\.fix\s+·\s+fix/
      assert_select "dd", text: "Writer"
      assert_select "[data-run-where]", text: "Laptop · term-7"
      assert_select "dd", text: "claude-sonnet-5-5 · medium effort"
      assert_select "[data-run-command]", text: "claude -p --model claude-sonnet-5-5 --verbose"
      assert_select "dd", text: "webhook · push · main"
      assert_select "dd", text: /queued .* · started .* · ended .* · 6m/m
    end
  end

  test "a run with no agent, runtime, model or command leaves those out, and a loader is named" do
    run = finished(skill: nil, loader: "catalog-import")
    get harbor.run_path(run)
    assert_response :success
    assert_select "h1", text: /Catalog Import/
    assert_select "#run-details dd", text: /loader\s+catalog-import/
    assert_select "#run-details dt", text: "Agent", count: 0
    assert_select "#run-details dt", text: "Where", count: 0
    assert_select "#run-details dt", text: "Model", count: 0
    assert_select "#run-details dt", text: "Command", count: 0
    assert_select "[data-run-facts]", count: 0
  end

  test "an agent that no longer exists is named by its key" do
    run = finished(agent_key: "retired")
    get harbor.run_path(run)
    assert_select "[data-run-facts]", text: /retired/
  end

  test "everything long on the page wraps instead of widening it" do
    run = finished(skill: "a.very.long.skill.name.that.would.not.fit.on.a.narrow.screen", agent_key: "writer", status: "error",
                   error: "x" * 300, command: "claude #{'--flag ' * 40}", workflow_run_id: 7, workflow_step_key: "review")
    Harbor::LiveLog.append(run.live_log_path, "#{'y' * 400}\n")
    get harbor.run_path(run)
    assert_select "#run-header h1.flex-wrap > span[class*='overflow-wrap:anywhere']", text: run.skill
    assert_select "#run-header p:not([class*='overflow-wrap:anywhere'])", count: 0
    assert_select "#run-details dl[class*='overflow-wrap:anywhere']"
    assert_select "#run-live-log h2.flex-wrap code[class*='overflow-wrap:anywhere']", text: run.live_log_path
    assert_select "pre:not([class*='overflow-wrap:anywhere'])", count: 0
    assert_select "#run-payloads > section.min-w-0", count: 2
  end

  test "an error is shown, and a run waiting for a model says that instead" do
    failed = finished(status: "error", error: "the test still fails")
    get harbor.run_path(failed)
    assert_select "#run-error h2", text: "Error"
    assert_select "#run-error pre.text-ink-red", text: "the test still fails"

    waiting = finished(status: "waiting_for_model", ended_at: nil, error: "No model is available.")
    get harbor.run_path(waiting)
    assert_select "#run-error h2", text: "Waiting for model"
    assert_select "#run-error pre.text-ink-yellow", text: "No model is available."
  end

  test "a workflow step names its workflow run, as plain text while no page for one exists" do
    run = finished(workflow_run_id: 7, workflow_step_key: "review")
    get harbor.run_path(run)
    assert_select "#run-header p", text: /Step\s+review\s+of\s+workflow run #7/
    assert_select "#run-header a", text: /workflow run/, count: 0
  end

  test "a run that doesn't exist is not found" do
    get harbor.run_path(0)
    assert_response :not_found
  end

  # --- the live log ---

  test "a running run's log follows its newest line and the page refreshes itself" do
    run = finished(status: "running", ended_at: nil)
    get harbor.run_path(run)
    assert_select "#run-live-log p", text: "Waiting for first output…"

    Harbor::LiveLog.append(run.live_log_path, "fetching rows\nwriting the report\n")
    get harbor.run_path(run)
    assert_select "#run-live-log .pill", text: "streaming"
    assert_select "#run-live-log code", text: run.live_log_path
    assert_select "#run-live-log pre[data-controller='harbor--log-follow'].overflow-y-auto", text: /fetching rows\nwriting the report/
    assert_select "[data-controller='harbor--poll'][data-harbor--poll-interval-value='5']", count: 1
  end

  test "a finished run's log is all on the page, and follows nothing" do
    run = finished
    Harbor::LiveLog.append(run.live_log_path, "fetching rows\nwriting the report\n")
    get harbor.run_path(run)
    assert_select "#run-live-log pre", text: /writing the report/
    assert_select "#run-live-log .pill", count: 0
    assert_select "[data-controller='harbor--log-follow']", count: 0
    assert_select "[data-controller='harbor--poll']", count: 0

    silent = finished(skill: "quiet-job")
    get harbor.run_path(silent)
    assert_select "#run-live-log p", text: "No log content was written for this run."
  end

  test "a run with nothing to name a log by has no log section; a queued one still refreshes" do
    run = Harbor::Run.create!(task_type: "fix", status: "queued")
    get harbor.run_path(run)
    assert_response :success
    assert_select "#run-live-log", count: 0
    assert_select "[data-controller='harbor--poll']", count: 1
  end

  # --- events, the raw stream, delegated runs ---

  test "the parsed events are listed in order, folded away" do
    run = finished
    run.run_events.create!(seq: 2, event_type: "assistant", tool_name: "Read", summary: "Read app/models/book.rb", occurred_at: Time.current)
    run.run_events.create!(seq: 1, event_type: "system", subtype: "init", summary: "session started", occurred_at: Time.current)
    get harbor.run_path(run)
    assert_select "#run-events details[data-controller='harbor--details'] summary", text: /2 stream events/
    lines = css_select("#run-events li").map { |li| li.text.squish }
    assert_equal [ "1. system/init session started", "2. assistant Read Read app/models/book.rb" ], lines

    get harbor.run_path(finished)
    assert_select "#run-events", count: 0
  end

  test "the raw stream downloads when the run kept one" do
    run = finished(skill: "writer.fix", agent_key: "writer")
    run.update!(raw_log_path: Harbor::AgentSession.raw_log_path(run))
    FileUtils.mkdir_p(File.dirname(run.raw_log_file))
    File.write(run.raw_log_file, %({"type":"result"}\n))

    get harbor.run_path(run)
    assert_select "[data-run-facts] a[href=?]", harbor.raw_run_path(run), text: "raw NDJSON"
    get harbor.raw_run_path(run)
    assert_response :success
    assert_equal "application/x-ndjson", response.media_type
    assert_match %(filename="run-#{run.id}.ndjson"), response.headers["Content-Disposition"]
    assert_equal %({"type":"result"}\n), response.body
  end

  test "with no raw stream there is no link, and asking for one says so" do
    run = finished(agent_key: "writer")
    get harbor.run_path(run)
    assert_select "a", text: "raw NDJSON", count: 0
    get harbor.raw_run_path(run)
    assert_redirected_to harbor.run_path(run)
    assert_equal "No raw log on disk for this run.", flash[:alert]

    run.update!(raw_log_path: "gone/run-#{run.id}.ndjson")
    get harbor.raw_run_path(run)
    assert_redirected_to harbor.run_path(run)
  end

  test "delegated runs are listed with what each cost, and a child names its parent" do
    parent = finished(skill: "writer.fix", agent_key: "writer", cost_usd_actual: 1.0)
    child = finished(skill: "writer.look-up", parent_run_id: parent.id, cost_usd_estimate: 0.25, input_tokens: 2000, output_tokens: 10)
    get harbor.run_path(parent)
    assert_select "#run-delegated-runs" do
      assert_select "li", text: /Writer\s+\(this run\)\s+\$0\.7500/
      assert_select "li[data-child-run='#{child.id}'] a[href=?]", harbor.run_path(child), text: "writer.look-up"
      assert_select "li[data-child-run='#{child.id}']", text: /2k in \/ 10 out\s+\$0\.2500/
      assert_select "li[data-child-run='#{child.id}'] [data-status=ok]"
      assert_select "li", text: /Total\s+\$1\.0000/
    end

    get harbor.run_path(child)
    assert_select "#run-header a[href=?]", harbor.run_path(parent), text: "run ##{parent.id} (writer.fix)"
    assert_select "#run-delegated-runs", count: 0
  end

  # --- Stop ---

  test "a running session can be stopped from its page and from the list" do
    run = start_session
    get harbor.run_path(run)
    assert_select "[data-run-actions] form[action=?] button", harbor.stop_run_path(run), text: "Stop run"
    get harbor.runs_path
    assert_select "li[data-run='#{run.id}'] form[action=?] button", harbor.stop_run_path(run), text: "Stop"

    post harbor.stop_run_path(run)
    assert_redirected_to harbor.run_path(run)
    assert_equal "Stopped run ##{run.id}.", flash[:notice]
    assert run.reload.canceled?
    assert_includes @orca.commands, "terminal close"
  end

  test "a queued run is canceled, with nothing to kill" do
    run = new_run(task_type: "fix")
    get harbor.run_path(run)
    assert_select "[data-run-actions] form[action=?] button", harbor.stop_run_path(run), text: "Cancel run"

    post harbor.stop_run_path(run)
    assert_redirected_to harbor.run_path(run)
    assert_equal "Canceled queued run ##{run.id}.", flash[:notice]
    assert run.reload.canceled?
    assert_equal "canceled while queued", run.error
    assert_empty @orca.commands
  end

  test "Stop isn't offered for anything else, and asking anyway changes nothing" do
    other = new_run(status: "running", started_at: Time.current)
    done = finished(agent_key: "writer")
    job = Harbor::Run.create!(loader: "catalog-import", status: "running")
    [ other, done, job ].each do |run|
      get harbor.run_path(run)
      assert_select "form[action=?]", harbor.stop_run_path(run), count: 0
      post harbor.stop_run_path(run)
      assert_redirected_to harbor.run_path(run)
      assert_match "can't be stopped", flash[:alert]
    end
    get harbor.runs_path
    assert_select "li[data-run] form", count: 0
    assert other.reload.running?
    assert done.reload.ok?
  end

  test "a host that can stop its own runs is asked to, with who pressed Stop" do
    asked = []
    Harbor.config.run_stop = ->(run, user) { asked << [ run.id, user.name ]; "Asked the worker to stop run ##{run.id}." }
    other = new_run(status: "running", started_at: Time.current)
    queued = new_run(task_type: "fix")
    session = start_session

    get harbor.run_path(other)
    assert_select "[data-run-actions] form[action=?] button", harbor.stop_run_path(other), text: "Stop run"
    post harbor.stop_run_path(other)
    assert_redirected_to harbor.run_path(other)
    assert_equal "Asked the worker to stop run ##{other.id}.", flash[:notice]

    post harbor.stop_run_path(queued)
    assert queued.reload.queued?, "a queued run is the host's to cancel too"
    post harbor.stop_run_path(session)
    assert session.reload.canceled?, "a session is still Harbor's"
    assert_equal [ [ other.id, "Sam Settings" ], [ queued.id, "Sam Settings" ] ], asked

    get harbor.run_path(finished(agent_key: "writer"))
    assert_select "[data-run-actions] form", count: 0
  end

  test "a host that couldn't stop a run says why" do
    Harbor.config.run_stop = ->(_run, _user) { raise "the worker isn't answering" }
    run = new_run(status: "running", started_at: Time.current)
    post harbor.stop_run_path(run)
    assert_redirected_to harbor.run_path(run)
    assert_equal "Run ##{run.id} wasn't stopped: the worker isn't answering", flash[:alert]
    assert run.reload.running?
  end

  # --- what a host adds, and what it replaces ---

  test "with no partials of the host's, the page has only Harbor's own" do
    run = finished(agent_key: "writer")
    get harbor.run_path(run)
    assert_select "[data-host-action], [data-host-meta], [data-host-extras], [data-host-agent], [data-host-details]", count: 0
    assert_select "[data-run-actions]", text: ""
    assert_select "#run-details", count: 1
  end

  test "a host's buttons, header line and sections are rendered where the page has a place for them" do
    host_views "extras"
    run = finished(agent_key: "writer")
    get harbor.run_path(run)
    assert_response :success
    assert_select "#run-header h1 [data-run-actions] button[data-host-action='#{run.id}']", text: "Run it again"
    assert_select "#run-header p [data-host-meta]", text: "asked for by Robin (run #{run.id})"
    assert_select "section[data-host-extras='#{run.id}']", text: "Verdicts on nightly-report"
    order = css_select("#run-details, #host-verdicts, #run-live-log, #run-payloads").map { |node| node["id"] }
    assert_equal %w[run-details host-verdicts run-live-log run-payloads], order, "the host's sections follow the details"
    assert_select "#run-details", count: 1, message: "what the host didn't replace is still Harbor's"
  end

  test "a host's partial of the same name replaces how an agent is shown, everywhere a run's agent is named" do
    host_views "overrides"
    parent = finished(skill: "writer.fix", agent_key: "writer", cost_usd_actual: 1.0)
    child = finished(agent_key: "writer", parent_run_id: parent.id)

    get harbor.runs_path
    assert_select "li[data-run='#{parent.id}'] [data-run-meta] [data-host-agent=writer][data-detail=false]", text: "agent WRITER"
    assert_select "li[data-run='#{parent.id}'] ul [data-host-agent=writer]", count: 1
    assert_select "li[data-run]", text: /Writer/, count: 0

    get harbor.run_path(parent)
    assert_select "[data-run-facts] [data-host-agent=writer][data-detail=true]", count: 1
    assert_select "#run-delegated-runs [data-host-agent=writer][data-detail=false]", count: 2
    assert_select "li[data-child-run='#{child.id}'] [data-host-agent=writer]", count: 1
  end

  test "a host's partial of the same name replaces the details" do
    host_views "overrides"
    run = finished
    get harbor.run_path(run)
    assert_select "section[data-host-details='#{run.id}']", text: "About nightly-report"
    assert_select "#run-details", count: 0
  end

  test "a host's own views are looked in before Harbor's" do
    paths = Harbor::RunsController.view_paths.map(&:to_s)
    host = paths.index(Rails.root.join("app/views").to_s)
    engine = paths.index(Harbor::Engine.root.join("app/views").to_s)
    assert host && engine, "both folders are view paths: #{paths.inspect}"
    assert_operator host, :<, engine
  end

  # --- the switch and the login ---

  test "the pages can be switched off, and need a login" do
    run = finished
    Harbor::Setting.set!(:page_runs, "false")
    [ harbor.runs_path, harbor.run_path(run), harbor.raw_run_path(run) ].each do |path|
      get path
      assert_response :not_found, "#{path} is still served with Runs off"
    end
    post harbor.stop_run_path(run)
    assert_response :not_found
    get "/reports"
    assert_not_includes css_select("[data-harbor-menu] a").map { |a| a.text.strip }, "Runs"

    Harbor::Setting.reset!(:page_runs)
    delete "/logout"
    [ harbor.runs_path, harbor.run_path(run), harbor.raw_run_path(run) ].each do |path|
      get path
      assert_redirected_to "/login"
    end
    post harbor.stop_run_path(run)
    assert_redirected_to "/login"
  end

  test "the pages live under Harbor's path, and other pages link to a run there" do
    run = finished
    assert_equal "/factory/runs", harbor.runs_path
    assert_equal "/factory/runs/#{run.id}", harbor.run_path(run)
    assert_equal "/factory/runs/#{run.id}/raw", harbor.raw_run_path(run)
    assert_equal "/factory/runs/#{run.id}/stop", harbor.stop_run_path(run)
    get "/reports"
    assert_select "[data-harbor-menu] a[href='/factory/runs']", text: "Runs"
  end
end
