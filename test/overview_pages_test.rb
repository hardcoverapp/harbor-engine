require "test_helper"

# The Overview page: what a site with no code of its own sees, the stage
# notes edited in place, the changes feed, and each place a host fills.
class HarborOverviewPagesTest < ActionDispatch::IntegrationTest
  include HarborOverviewSetup

  EXTRAS = File.expand_path("fixtures/host_views/extras", __dir__)
  OVERRIDES = File.expand_path("fixtures/host_views/overrides", __dir__)
  CONTROLLERS = [ Harbor::OverviewController, Harbor::StageNotesController ].freeze

  setup do
    @view_paths = CONTROLLERS.index_with(&:view_paths)
    post "/login", params: { name: "Sam Settings" }
  end

  teardown { @view_paths.each { |controller, paths| controller.view_paths = paths } }

  # What a host does: a views folder of its own, looked in before Harbor's.
  def host_views(folder) = CONTROLLERS.each { |controller| controller.prepend_view_path(folder) }

  def tile(key) = css_select("#at-a-glance [data-tile=#{key}]").first

  # --- a site with no code of its own ---

  test "Overview is the section's own address, first in the menu and current only there" do
    assert_equal "/factory", harbor.overview_path
    get "/factory"
    assert_response :success
    assert_select "title", text: "Overview"
    assert_select "h1", text: "Overview"
    assert_equal %w[Overview Velocity], css_select("[data-harbor-menu] a").first(2).map { |a| a.text.strip }
    assert_select "[data-harbor-menu] a.current", text: "Overview", count: 1
    assert_select "[data-harbor-nav] a[aria-current=page]", text: "Overview", count: 1
    get harbor.velocity_path
    assert_select "[data-harbor-menu] a.current", text: "Velocity", count: 1
  end

  test "with nothing recorded the page still says what is set up, and shows no host section" do
    [ Harbor::TaskAssignment, Harbor::Agent, Harbor::ModelChoice, Harbor::ModelAlias, Harbor::ModelProvider ].each(&:delete_all)
    Harbor::TaskTypes.reset!
    get harbor.overview_path
    assert_response :success
    assert_equal "0", tile(:runs).at_css(".display").text.strip
    assert_equal "$0.00", tile(:spend).at_css(".display").text.strip
    assert_select "#lifecycle h2", text: "What is set up"
    assert_select "#stage-work h3", text: "Work"
    assert_select "#stage-work h4", count: 0
    assert_select "nav[aria-label=Stages]", count: 0
    assert_select "#ways-in", count: 0
    assert_select "#how-to-steer", count: 0
    assert_select "#changes p", text: "No changes recorded yet."
  end

  test "a site with no host code sees real numbers from its runs and everything it has set up" do
    finished("review", minutes: 3, cost: 1.25, agent_key: "writer")
    finished("review", minutes: 5, status: "error", cost: 0.5, agent_key: "writer")
    Harbor::Run.create!(task_type: "review", status: "running")
    wf = workflow("tidy", "Tidy up", manual([ agent_step("writer"), agent_step("task:review").merge("key" => "check", "name" => "Check it") ]))
    sweep = automation("sweep", "Sweep the shelf")
    automation("off", "Switched off", enabled: false)

    get harbor.overview_path
    assert_response :success
    assert_equal %w[runs spend agents workflows automations runtimes scorers proposals reviews],
                 css_select("#at-a-glance [data-tile]").map { |card| card["data-tile"] }
    assert_equal [ "Runs", "3", "1 failed · 1 under way now" ], tile(:runs).css("div").map { |div| div.text.strip }
    assert_equal [ "Spend", "$1.75", "2 runs with a cost" ], tile(:spend).css("div").map { |div| div.text.strip }
    assert_select "#at-a-glance [data-tile=runs] a[href=?]", harbor.runs_path
    assert_select "#at-a-glance [data-tile=spend] a[href=?]", harbor.velocity_path(tab: "spending", range: "30d")
    assert_equal "2", tile(:agents).at_css(".display").text.strip
    assert_equal "1", tile(:workflows).at_css(".display").text.strip
    assert_equal "1", tile(:automations).at_css(".display").text.strip

    # Who does it: every declared task type, as routing would hand it out.
    routing = css_select("#stage-work li").select { |li| li.at_css("code.chip") && li.at_css("a[href^='/factory/agents']") }
    assert_equal [ "review Wren · Thinking · high effort", "rebase Wren · Thinking · high effort (falls back to review)",
                   "triage Piper (default)", "audit unassigned" ], routing.map { |li| li.text.squish }
    assert_select "#stage-work a[href=?]", harbor.agent_path(@writer), text: "Wren · Thinking · high effort", count: 2
    assert_select "#stage-work a.text-ink-red[href=?]", harbor.agents_path, text: "unassigned"

    # What it runs.
    assert_select "#stage-work a[href=?]", harbor.workflow_path(wf), text: "Tidy up"
    assert_select "#stage-work li", text: /Tidy up\s+live\s+workflow v1\s+· Do it → Check it/
    assert_select "#stage-work a[href=?]", harbor.edit_automation_path(sweep), text: "Sweep the shelf"
    assert_select "#stage-work li", text: /Sweep the shelf\s+on\s+automation · weekly on Sat at 03:00/
    assert_select "#stage-work li", text: /Switched off\s+off\s+automation/
    assert_select "#lifecycle h3", text: "Also running", count: 0

    # How long, what it costs.
    assert_select "#stage-work h4", text: /How long, what it costs\s+· last 30 days/
    assert_equal [ "review", "3m", "3m", "$0.88", "1 +1 failed" ], css_select("#stage-work tbody tr td").map { |td| td.text.squish }
    assert_select "#stage-work td[title='p90 $1.18']", text: "$0.88"

    # What changed.
    assert_select "#changes li", text: /Workflow\s+Tidy up v1\s+created\s+— · less than a minute ago/
    assert_select "#changes li a[href=?]", harbor.workflow_path(wf), text: "Tidy up v1"
    assert_select "#changes a[aria-current=page]", text: "Recent"
  end

  test "the changes feed filters to this week" do
    old = Harbor::AgentSetting.create!(key: "shared/old.md", body: "x")
    old.update_columns(updated_at: 3.weeks.ago)
    Harbor::AgentSetting.create!(key: "shared/new.md", body: "x")
    get harbor.overview_path
    assert_select "#changes li", text: /old\.md/
    get harbor.overview_path(changes: "week")
    assert_select "#changes li", text: /new\.md/
    assert_select "#changes li", text: /old\.md/, count: 0
    assert_select "#changes a[aria-current=page]", text: "This week"
    assert_select "#changes a[href=?]", "/factory#changes", text: "Recent"

    Harbor::AgentSetting.delete_all
    [ Harbor::Agent, Harbor::TaskAssignment, Harbor::ModelChoice ].each { |model| model.update_all(updated_at: 1.year.ago) }
    get harbor.overview_path(changes: "week")
    assert_select "#changes p", text: "Nothing changed this week."
  end

  # --- stage notes ---

  test "a stage with no note shows its summary and offers to write one" do
    get harbor.overview_path
    assert_select "turbo-frame#factory-note-work p", text: /Every kind of work set up here/
    assert_select "turbo-frame#factory-note-work a[href=?]", harbor.edit_stage_note_path("work"), text: "Write what happens here"
  end

  test "a note is edited in place, kept outside the database, and shown on the page and in the feed" do
    exported = []
    Harbor.config.export = ->(path, body) { exported << [ path, body ] }
    get harbor.edit_stage_note_path("work")
    assert_response :success
    assert_select "turbo-frame#factory-note-work form[action=?]", harbor.stage_note_path("work")
    assert_select "turbo-frame#factory-note-work textarea[name='factory_note[body]']"
    assert_select "label", text: "What happens in Work"
    assert_select "[data-host-note-hint]", count: 0

    patch harbor.stage_note_path("work"), params: { factory_note: { body: " Sam reads **every** order. " } },
                                          headers: { "Accept" => "text/vnd.turbo-stream.html" }
    assert_response :success
    assert_match %(<turbo-stream action="replace" target="factory-note-work">), response.body
    assert_includes response.body, "Sam reads **every** order."
    note = Harbor::StageNote.find_by!(stage_key: "work")
    assert_equal "Sam reads **every** order.", note.body
    assert_equal [ "factory/notes/work.md" ], exported.map(&:first)
    assert_match(/\A---\nstage: work\nupdated_at: .*\n---\n\nSam reads \*\*every\*\* order\.\n\z/, exported.first.last)

    get harbor.stage_note_path("work")
    assert_select "turbo-frame#factory-note-work .md p", text: "Sam reads **every** order."
    assert_select "turbo-frame#factory-note-work a[href=?]", harbor.edit_stage_note_path("work"), text: "Edit"
    assert_select "turbo-frame#factory-note-work p.meta", text: /\Aedited less than a minute ago/

    get harbor.overview_path
    assert_select "#stage-work .md", text: "Sam reads **every** order."
    assert_select "#changes li", text: /Stage note\s+Work\s+note edited/
    assert_select "#changes li a[href=?]", "/factory#stage-work", text: "Work"
  end

  test "without a turbo stream a save goes back to the stage, and an unknown stage is not found" do
    patch harbor.stage_note_path("work"), params: { factory_note: { body: "Plain." } }
    assert_redirected_to "/factory#stage-work"
    follow_redirect!
    assert_select "[data-notice]", text: "Saved the Work note."
    get harbor.edit_stage_note_path("nope")
    assert_response :not_found
    patch harbor.stage_note_path("nope"), params: { factory_note: { body: "x" } }
    assert_response :not_found
  end

  test "a note is markdown where the host says how markdown is drawn, and so is a line of steering" do
    Harbor.config.markdown = ->(text) { "<p>#{ERB::Util.html_escape(text).gsub(/\*\*(.+?)\*\*/, '<strong>\1</strong>').gsub(/`(.+?)`/, '<code>\1</code>')}</p>" }
    Harbor::StageNote.create!(stage_key: "work", body: "Sam reads **every** order. <script>")
    Harbor::Overview.steer "hold", want: "Pause it", action: "add the `hold` label", result: "work **stops**", stage: "work"
    get harbor.overview_path
    assert_select "#stage-work .md strong", text: "every"
    assert_select "#stage-work .md script", count: 0
    assert_select "tr#steer-hold td code", text: "hold"
    assert_select "tr#steer-hold td p", count: 0, message: "a line inside a sentence is not a paragraph"
    assert_select "tr#steer-hold td strong", text: "stops"
    get harbor.edit_stage_note_path("work")
    assert_select "label", text: "What happens in Work (markdown)"
  end

  test "Overview switched off is not found, notes and all, and leaves the menu" do
    Harbor::Setting.set!(:page_overview, "false")
    get harbor.overview_path
    assert_response :not_found
    get harbor.edit_stage_note_path("work")
    assert_response :not_found
    patch harbor.stage_note_path("work"), params: { factory_note: { body: "x" } }
    assert_response :not_found
    get harbor.velocity_path
    assert_not_includes css_select("[data-harbor-menu] a").map { |a| a.text.strip }, "Overview"
  end

  # --- what a host declares ---

  test "a host's stages lay the page out in the order work moves, with what belongs to no stage below" do
    declare_stages
    Harbor::Workflows.register_claim "reviewing", "Review asked for → ReviewJob"
    claimed = workflow("claimed", "Second look", manual([ agent_step("writer") ]), claims: %w[reviewing], mode: "dry_run")
    loose = workflow("loose", "Loose end", manual([ agent_step("writer") ]), mode: "off")
    automation("sweep", "Sweep the shelf")
    stray = automation("stray", "Stray", trigger_kind: "manual", cron: nil)
    finished("review", minutes: 4, cost: 2)
    Harbor::StageNote.create!(stage_key: "ship", body: "Out it goes.")

    get harbor.overview_path
    assert_select "#lifecycle h2", text: "The lifecycle"
    assert_equal [ "Triage", "Review", "Ship" ], css_select("nav[aria-label=Stages] a").map(&:text)
    assert_equal [ "#stage-triage", "#stage-review", "#stage-ship" ], css_select("nav[aria-label=Stages] a").map { |a| a["href"] }
    assert_equal [ "01 Triage", "02 Review", "03 Ship" ], css_select("#lifecycle ol > li > div:first-child").map { |div| div.text.squish }
    assert_select "#stage-triage turbo-frame p", text: "A ticket is read."
    assert_select "#stage-triage li", text: /triage\s+Piper\s+\(default\)/
    assert_select "#stage-triage a", text: "Sweep the shelf"
    assert_select "#stage-review li", text: /review\s+Wren · Thinking · high effort/
    assert_select "#stage-review a[href=?]", harbor.workflow_path(claimed), text: "Second look"
    assert_select "#stage-review li", text: /Second look\s+dry run/
    assert_select "#stage-review td", text: "4m"
    assert_select "#stage-ship .md", text: "Out it goes."
    assert_select "#stage-ship h4", count: 0
    also = css_select("#lifecycle > div.card").sole
    assert_equal "Also running", also.at_css("h3").text
    assert_equal [ harbor.workflow_path(loose), harbor.edit_automation_path(stray) ], also.css("a").map { |a| a["href"] }
  end

  test "a host's part adds its lines under What it runs, on the stages it says" do
    declare_stages
    Harbor::Overview.part(:checks, "Checks") do |stage, _snapshot|
      next [] unless stage.key == "review"
      [ Harbor::Overview::Item.new(label: "Spelling", mode: "live", url: "/checks/spelling", detail: "every change"),
        Harbor::Overview::Item.new(label: "Tone") ]
    end
    Harbor::Overview.part(:sign_offs, "Sign-offs") { |stage, _| stage.key == "ship" ? [ Harbor::Overview::Item.new(label: "Owner") ] : [] }
    get harbor.overview_path
    assert_select "#stage-review a[href='/checks/spelling']", text: "Spelling"
    assert_select "#stage-review li", text: /Spelling\s+live\s+check · every change/
    assert_select "#stage-review li", text: /Tone\s+check\z/
    assert_select "#stage-ship li", text: /Owner\s+sign-off/
    assert_select "#stage-triage li", text: /check|sign-off/, count: 0
  end

  test "a host's ways in and steering rows make their sections, and mark their stages" do
    declare_stages
    Harbor::Overview.way_in "desk", title: "The help desk", body: "A ticket opened there.", stage: "triage", task_type: "triage"
    Harbor::Overview.way_in "door", title: "The front door", body: "Someone walks in.", stage: "nowhere"
    Harbor::Overview.steer "hold", want: "Pause it", action: "add the hold label", result: "work stops", stage: "review"
    Harbor::Overview.steer "ship", want: "Ship it", action: "press Ship", result: "it goes out", stage: "elsewhere"

    get harbor.overview_path
    assert_equal [ "Ways in", "The lifecycle", "How to steer", "What changed" ],
                 css_select("div.harbor-page > section > h2, div.harbor-page > section > div > h2").map { |h| h.text.strip } - [ "At a glance · last 30 days" ]
    cards = css_select("#ways-in article")
    assert_equal [ "The help desk", "The front door" ], cards.map { |card| card.at_css("p").text }
    assert_equal "triage → Piper · starts at Triage", cards.first.at_css("p.meta").text.squish
    assert_select "#ways-in article a[href='#stage-triage']", text: "Triage"
    assert_equal "", cards.last.at_css("p.meta").text.squish
    assert_equal [ "Pause it add the hold label work stops Review", "Ship it press Ship it goes out elsewhere" ],
                 css_select("#how-to-steer tbody tr").map { |row| row.text.squish }
    assert_select "tr#steer-hold a[href='#stage-review']", text: "Review"
    assert_select "#stage-review h4", text: "Where people come in"
    assert_select "#stage-review li", text: /Pause it:\s+add the hold label/
    assert_select "#stage-triage h4", text: "Where people come in", count: 0
  end

  test "a host's tile and section appear where they are declared, and a section of Harbor's can be left out" do
    host_views(EXTRAS)
    Harbor::Overview.tile(:tickets, label: "Tickets", after: :runs) { |_since| { value: 12, note: "open", url: "/tickets" } }
    Harbor::Overview.section :costs, partial: "host/overview/costs", after: :lifecycle
    get harbor.overview_path
    assert_response :success
    assert_equal %w[runs tickets spend], css_select("#at-a-glance [data-tile]").first(3).map { |card| card["data-tile"] }
    assert_equal [ "Tickets", "12", "open" ], tile(:tickets).css("div").map { |div| div.text.strip }
    assert_select "#at-a-glance [data-tile=tickets] a[href='/tickets']", text: "12"
    assert_equal %w[at-a-glance lifecycle host-costs changes], css_select("div.harbor-page > section").map { |section| section["id"] }
    assert_select "[data-host-section] p", text: "1 stages since #{30.days.ago.to_date}"

    Harbor::Overview.hide_section :summary
    Harbor::Overview.section :costs, partial: "host/overview/costs", before: :lifecycle
    get harbor.overview_path
    assert_equal %w[host-costs lifecycle changes], css_select("div.harbor-page > section").map { |section| section["id"] }
  end

  test "a host says what the page is in its own words, names it, and adds a line to the note form" do
    host_views(OVERRIDES)
    host_views(EXTRAS)
    get harbor.overview_path
    assert_select "title", text: "The shop floor"
    assert_select "header h1[data-host-intro]", text: "Shop floor"
    assert_select "h1", count: 1
    assert_select "#lifecycle", count: 1
    get harbor.edit_stage_note_path("work")
    assert_select "turbo-frame#factory-note-work form [data-host-note-hint]", text: "Kept in the shared drive too."
  end
end
