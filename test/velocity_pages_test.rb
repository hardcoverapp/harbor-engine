require "test_helper"

# The Velocity page: what a site with no code of its own sees on each tab
# and over each range, and each place a host fills.
class HarborVelocityPagesTest < ActionDispatch::IntegrationTest
  include HarborOverviewSetup

  EXTRAS = File.expand_path("fixtures/host_views/extras", __dir__)
  OVERRIDES = File.expand_path("fixtures/host_views/overrides", __dir__)

  setup do
    @view_paths = Harbor::VelocityController.view_paths
    post "/login", params: { name: "Sam Settings" }
  end

  teardown { Harbor::VelocityController.view_paths = @view_paths }

  # What a host does: a views folder of its own, looked in before Harbor's.
  def host_views(folder) = Harbor::VelocityController.prepend_view_path(folder)

  # Each tile of the row at the top, as [label, value, note].
  def tiles = css_select("div.harbor-page > div.grid.mb-8 > div.card").map { |card| card.css("div").map { |div| div.text.squish } }

  def card(heading) = css_select("section.card").find { |section| section.at_css(".meta")&.text&.strip == heading }

  def rows(heading) = card(heading).css("tbody tr").map { |row| row.css("td").map { |td| td.text.squish } }

  def record_work
    laptop = Harbor::Runtime.create!(key: "laptop", name: "Laptop", backend: "orca", config: { "repo" => "name:app" })
    parent = finished("review", minutes: 2, cost: 3.0, agent_key: "writer", model: "claude-sonnet-5-5", runtime_id: laptop.id)
    finished("review", minutes: 4, cost: 1.0, agent_key: "writer", parent_run_id: parent.id, model: "claude-haiku-5-5")
    finished("review", minutes: 9, agent_key: "writer", status: "error")
    finished("triage", minutes: 6, cost: 0.5, agent_key: "planner", started: 20.days.ago)
    finished("review", minutes: 2, cost: 1200, started: 100.days.ago, agent_key: "writer")
    Harbor::Run.create!(task_type: "review", status: "running", agent_key: "writer")
    scorer = Harbor::Scorer.create!(name: "Ran the tests", description: "Did it run them?", judge_instructions: "Did it?", model_alias: @alias,
                                    sample_rate: 0, pass_threshold: 1.0,
                                    classifications: [ { "label" => "pass", "score" => 1.0 }, { "label" => "fail", "score" => 0.0 } ])
    judge = finished(nil, minutes: 1, cost: 0.02, skill: Harbor::Scorer::JUDGE_SKILL, parent_run_id: parent.id)
    Harbor::ScorerResult.create!(scorer:, run: parent, judge_run: judge, status: "ok", passed: true, classification: "pass", score: 1, scored_at: 1.day.ago)
    Harbor::ScorerResult.create!(scorer:, run: Harbor::Run.find_by!(status: "error"), status: "ok", passed: false, classification: "fail", score: 0,
                                 scored_at: 1.day.ago)
    scorer
  end

  # --- a site with no code of its own ---

  test "the page opens on Runs over the last twelve weeks, with a tab for each of Harbor's" do
    get harbor.velocity_path
    assert_response :success
    assert_equal "/factory/velocity", harbor.velocity_path
    assert_select "title", text: "Velocity"
    assert_select "h1", text: "Velocity"
    assert_equal %w[Runs Spending Scorers], css_select("a.pill").map(&:text)
    assert_equal [ "/factory/velocity?range=12w&tab=runs", "/factory/velocity?range=12w&tab=spending", "/factory/velocity?range=12w&tab=scorers" ],
                 css_select("a.pill").map { |a| a["href"] }
    assert_select "a.pill.bg-ink", text: "Runs", count: 1
    assert_select "form[action=?][method=get][data-controller='harbor--autosubmit']", harbor.velocity_path
    assert_select "form input[type=hidden][name=tab][value=runs]"
    assert_select "select[name=range][data-action='change->harbor--autosubmit#submit'] option[selected][value='12w']", text: "Last 12 weeks"
    assert_equal [ "Last 7 days", "Last 30 days", "Last 90 days", "Last 12 weeks", "Last 6 months" ], css_select("select[name=range] option").map(&:text)
    assert_select "[data-harbor-menu] a.current", text: "Velocity"
  end

  test "with no runs every tab says so" do
    get harbor.velocity_path
    assert_equal [ [ "Runs", "0", "0 under way" ], [ "Ended ok", "0", "finished as they should" ], [ "Failed", "0", "errors and timeouts" ],
                   [ "Median time", "—", "runs that ended ok" ] ], tiles
    assert_select "p", text: "No runs in this range."
    assert_equal [ [ "No agent runs in this range." ] ], rows("Runs by agent — outcome")
    assert_equal [ [ "No run was placed on a runtime in this range." ] ], rows("Runs by runtime")

    get harbor.velocity_path(tab: "spending")
    assert_equal [ [ "Spend", "$0.00", "CLI-reported actuals" ], [ "Runs", "0", "0 with a cost" ], [ "Per run", "—", "mean, costed runs" ] ], tiles
    assert_select "p", text: "No costed runs in this range."
    assert_equal [ [ "No agent spend in this range." ] ], rows("Spend by agent")

    Harbor::Scorer.delete_all
    get harbor.velocity_path(tab: "scorers")
    assert_equal [ [ "Judgements", "0", "judge runs in range" ], [ "Judge spend", "$0.00", "what the scoring cost" ],
                   [ "Scorers", "0 enabled", "Manage scorers" ] ], tiles
    assert_select "p a[href=?]", harbor.new_scorer_path, text: "create one"
  end

  test "a site with no host code sees its runs: how many, how they ended, and whose they were" do
    record_work
    get harbor.velocity_path(tab: "runs", range: "30d")
    assert_response :success
    assert_equal [ [ "Runs", "6", "1 under way" ], [ "Ended ok", "4", "finished as they should" ],
                   [ "Failed", "1", "20% of the runs that ended" ], [ "Median time", "3m", "runs that ended ok" ] ], tiles
    assert_select "div.grid.lg\\:grid-cols-4.mb-8", count: 1
    assert_select "section.card .spark .spark-col", minimum: 4
    assert_equal [ %w[planner 1 0 0%], %w[writer 2 1 33%] ], rows("Runs by agent — outcome")
    assert_equal [ %w[review 3], %w[triage 1] ], rows("Runs by task type")
    assert_equal [ %w[Laptop 1] ], rows("Runs by runtime")

    get harbor.velocity_path(tab: "runs", range: "7d")
    assert_equal "5", tiles.first[1], "the run of twenty days ago is outside the last seven"
    get harbor.velocity_path(tab: "runs", range: "6m")
    assert_equal "7", tiles.first[1]
  end

  test "a site with no host code sees what its agents spent, by week, agent and model" do
    record_work
    get harbor.velocity_path(tab: "spending", range: "30d")
    assert_response :success
    assert_equal [ [ "Spend", "$3.52", "CLI-reported actuals" ], [ "Runs", "5", "3 with a cost" ], [ "Per run", "$1.17", "mean, costed runs" ] ], tiles
    assert_select "div.grid.lg\\:grid-cols-3.mb-8", count: 1
    assert_select "a.pill.bg-ink", text: "Spending"
    assert_select "form input[type=hidden][name=tab][value=spending]"
    assert_equal [ [ "writer 3 runs", "$3.00" ], [ "planner 1 runs", "$0.50" ] ], rows("Spend by agent")
    assert_equal [ [ "claude-sonnet-5-5 1 runs", "$3.00" ], [ "(unknown) 2 runs", "$0.52" ] ], rows("Spend by model")
    assert_select "[data-host-spending-card]", count: 0

    get harbor.velocity_path(tab: "spending", range: "6m")
    assert_equal [ "Spend", "$1,203.52", "CLI-reported actuals" ], tiles.first
  end

  test "a site with no host code sees each scorer's pass rate and what the judging cost" do
    scorer = record_work
    Harbor::Scorer.create!(name: "Quiet", judge_instructions: "Anything?", model_alias: @alias, sample_rate: 0, pass_threshold: 1.0, enabled: false,
                           classifications: [ { "label" => "pass", "score" => 1.0 }, { "label" => "fail", "score" => 0.0 } ])
    get harbor.velocity_path(tab: "scorers", range: "30d")
    assert_response :success
    assert_equal [ [ "Judgements", "1", "judge runs in range" ], [ "Judge spend", "$0.02", "what the scoring cost" ],
                   [ "Scorers", "1 enabled", "Manage scorers" ] ], tiles
    assert_select "div.card.sm\\:col-span-2 a[href=?]", harbor.scorers_path, text: "Manage scorers"
    cards = css_select("div.grid.lg\\:grid-cols-2 > section.card")
    assert_equal [ "Quiet", "Ran the tests" ], cards.map { |c| c.at_css("a").text }.sort
    judged = cards.find { |c| c.at_css("a").text == "Ran the tests" }
    assert_equal harbor.scorer_path(scorer), judged.at_css("a")["href"]
    assert_equal "50% pass · 2 judged", judged.at_css("span.ml-auto").text.squish
    assert_equal [ "fail 1", "pass 1" ], judged.css("span.pill").map { |pill| pill.text.squish }.sort
    assert_equal 1, judged.css("span.pill.bg-pale-green").size
    quiet = cards.find { |c| c.at_css("a").text == "Quiet" }
    assert_equal [ "off" ], quiet.css("span.pill").map(&:text)
    assert_equal "nothing judged · 0 judged", quiet.at_css("span.ml-auto").text.squish
    assert_includes quiet.text, "No verdicts in this range."
  end

  test "a tab or a range that isn't one falls back, and every range opens every tab" do
    get harbor.velocity_path(tab: "nope", range: "1y")
    assert_response :success
    assert_select "a.pill.bg-ink", text: "Runs"
    assert_select "option[selected][value='12w']"
    Harbor::Velocity::RANGES.each_key do |range|
      Harbor::Velocity.tabs.each do |tab|
        get harbor.velocity_path(range:, tab: tab.key)
        assert_response :success, "#{tab.key} over #{range}"
        assert_select "option[selected][value=?]", range
      end
    end
  end

  test "Velocity switched off is not found and leaves the menu" do
    Harbor::Setting.set!(:page_velocity, "false")
    get harbor.velocity_path
    assert_response :not_found
    get harbor.overview_path
    assert_not_includes css_select("[data-harbor-menu] a").map { |a| a.text.strip }, "Velocity"
    assert_select "#at-a-glance [data-tile=spend]", count: 0
  end

  # --- what a host declares ---

  test "a host's tab appears where it is declared and is drawn from its own partial, with the period" do
    host_views(EXTRAS)
    Harbor::Velocity.tab "tickets", label: "Tickets", partial: "host/velocity/tickets", before: "runs"
    get harbor.velocity_path(range: "7d")
    assert_response :success
    assert_equal %w[Tickets Runs Spending Scorers], css_select("a.pill").map(&:text)
    assert_select "a.pill.bg-ink", text: "Tickets", count: 1, message: "the first tab is the one the page opens on"
    assert_select "[data-host-tab] p", text: "Since #{7.days.ago.to_date}: 7 closed"
    assert_select "form input[type=hidden][name=tab][value=tickets]"

    get harbor.velocity_path(tab: "spending")
    assert_select "[data-host-tab]", count: 0
    assert_select "a.pill.bg-ink", text: "Spending"
  end

  test "a host takes away a tab of Harbor's it replaces" do
    host_views(EXTRAS)
    Harbor::Velocity.tab "tickets", label: "Tickets", partial: "host/velocity/tickets", before: "runs"
    Harbor::Velocity.remove_tab "runs"
    get harbor.velocity_path
    assert_equal %w[Tickets Spending Scorers], css_select("a.pill").map(&:text)
    get harbor.velocity_path(tab: "runs")
    assert_select "[data-host-tab]", count: 1, message: "a tab that is gone falls back to the first"
  end

  test "a host's tile sits after the tile it names, and the row widens for it" do
    record_work
    seen = []
    Harbor::Velocity.tile("spending", :per_ticket, label: "Per ticket", note: "median", after: :runs) do |period|
      seen << period
      "$2.00"
    end
    Harbor::Velocity.tile("runs", :tickets, label: "Tickets", note: "closed") { |_period| 7 }
    get harbor.velocity_path(tab: "spending", range: "30d")
    assert_equal [ "Spend", "Runs", "Per ticket", "Per run" ], tiles.map(&:first)
    assert_equal [ "Per ticket", "$2.00", "median" ], tiles[2]
    assert_select "div.grid.lg\\:grid-cols-4.mb-8", count: 1
    assert_equal 30.days.ago.to_date, seen.sole.since.to_date

    get harbor.velocity_path(tab: "runs")
    assert_equal [ "Tickets", "7", "closed" ], tiles.last
    get harbor.velocity_path(tab: "scorers")
    assert_equal %w[Judgements Judge\ spend Scorers], tiles.map(&:first)
  end

  test "a host's cards join the grid of the tab they are for" do
    host_views(EXTRAS)
    get harbor.velocity_path(tab: "spending", range: "7d")
    grid = css_select("div.grid.lg\\:grid-cols-2 > section")
    assert_equal "Spend by customer since #{7.days.ago.to_date}", grid.first.text.strip, "ahead of Harbor's own"
    assert_equal 3, grid.size
    get harbor.velocity_path(tab: "runs", range: "7d")
    grid = css_select("div.grid.lg\\:grid-cols-2 > section")
    assert_equal "Runs by customer since #{7.days.ago.to_date}", grid.last.text.strip
    assert_equal 4, grid.size
  end

  test "a host says what the page is in its own words and names it" do
    host_views(OVERRIDES)
    get harbor.velocity_path
    assert_select "title", text: "Pace"
    assert_select "header h1[data-host-intro]", text: "Pace"
    assert_select "h1", count: 1
    assert_select "select[name=range]", count: 1
  end
end
