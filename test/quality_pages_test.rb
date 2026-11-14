require "test_helper"

# The Scorers and Proposals pages, and the scores on a run's page: what a site
# with no code of its own gets, and each place a host can add to or replace.
class HarborQualityPagesTest < ActionDispatch::IntegrationTest
  include HarborQuality

  # A host's scorer class: a task type of its own, and a judge it starts
  # every new scorer with.
  class HostScorer < Harbor::Scorer
    def self.task_types = super + %w[automation]
    def self.draft = super.tap { |scorer| scorer.model_alias = Harbor::ModelAlias.order(:id).first }
  end

  # A host's proposal class: it knows who its users are.
  class HostProposal < Harbor::Proposal
    def applied_by_name = applied_by_user_id && "user ##{applied_by_user_id}"
  end

  HOST_VIEWS = File.expand_path("fixtures/host_views", __dir__)
  CONTROLLERS = [ Harbor::ScorersController, Harbor::ProposalsController, Harbor::RunsController ].freeze
  VERDICT = "```json\n{\"classification\":\"fail\",\"score\":0,\"reasoning\":\"Pushed without running the tests.\"}\n```".freeze

  setup do
    Harbor::TaskTypes.reset!
    Harbor::TaskTypes.declare "review"
    Harbor::TaskTypes.declare "rebase"
    @view_paths = CONTROLLERS.index_with(&:view_paths)
    post "/login", params: { name: "Sam Settings" }
  end

  teardown do
    CONTROLLERS.each { |controller| controller.view_paths = @view_paths[controller] }
    Harbor::TaskTypes.reset!
  end

  # What a host does: a views folder of its own, looked in before Harbor's.
  def host_views(name) = CONTROLLERS.each { |controller| controller.prepend_view_path(File.join(HOST_VIEWS, name)) }

  def current_page = css_select("[data-harbor-nav] a[aria-current=page]").map { |a| a.text.strip }

  def guide_parts = css_select("section[data-quality-guide] > ol > li").map { |li| li.css("p").first(2).map { |p| p.text.squish } }

  def proposal(**attributes)
    Harbor::Proposal.create!({ agent_key: "writer", target_kind: "agent_prompt", summary: "Require a test run",
                               before: "Be careful.", after: "Be careful.\nRun the tests." }.merge(attributes))
  end

  def register_handbook
    Harbor::Proposals.register_target "handbook_page", label: ->(page) { "handbook · #{page.document_path}" }
  end

  # --- a site with no code of its own ---

  test "a site with no code of its own writes a scorer on the page, scores a run with it and sees the verdict" do
    Harbor.config.scorer_judge = ->(judgement) { judgement.judge.update!(cost_usd_actual: 0.0123) && VERDICT }
    run = agent_run

    get harbor.scorers_path
    assert_response :success
    assert_select "td", text: "No scorers yet."
    get harbor.new_scorer_path
    assert_response :success
    post harbor.scorers_path, params: { scorer: {
      name: "Ran the tests", description: "Did it run the tests before pushing?", judge_instructions: "Look for a test run after the last edit.",
      model_alias_id: @alias.id, sample_rate: 0, pass_threshold: 1, classifications_text: "pass=1\nfail=0",
      agent_keys: [ "", "writer" ], task_types: [ "" ], enabled: "1", self_improvement: "1" } }
    scorer = Harbor::Scorer.sole
    assert_redirected_to harbor.scorer_path(scorer)
    assert_equal "Ran the tests saved. It applies to runs that finish from now on.", flash[:notice]
    assert_equal [ %w[pass fail], %w[writer], [], true, true ], [ scorer.labels, scorer.agent_keys, scorer.task_types, scorer.enabled, scorer.self_improvement ]

    get harbor.run_path(run)
    assert_select "#run-scores form[action=?] select[name=scorer_id] option", harbor.score_run_path(run), text: "Ran the tests"
    perform_enqueued_jobs(only: Harbor::Scorers::EvaluateJob) { post harbor.score_run_path(run, scorer_id: scorer.id) }
    assert_redirected_to harbor.run_path(run)
    assert_equal "Judging run ##{run.id} with Ran the tests — the verdict appears here shortly.", flash[:notice]

    result = Harbor::ScorerResult.sole
    get harbor.run_path(run)
    assert_select "#run-scores li##{ActionView::RecordIdentifier.dom_id(result)}" do
      assert_select "a[href=?]", harbor.scorer_path(scorer), text: "Ran the tests"
      assert_select ".pill.bg-pale-red", text: "fail · 0.0"
      assert_select "a[href=?]", harbor.run_path(result.judge_run), text: "judge run ##{result.judge_run.id}"
      assert_select "details p", text: "Pushed without running the tests."
    end

    get harbor.scorer_path(scorer)
    assert_response :success
    assert_select "tbody tr", count: 1 do
      assert_select "a[href=?]", harbor.run_path(run), text: "##{run.id} writer.review"
      assert_select ".pill.bg-pale-red", text: "fail · 0.0"
      assert_select "td", text: "Pushed without running the tests."
      assert_select "a[href=?]", harbor.run_path(result.judge_run), text: "##{result.judge_run.id}"
      assert_select "td", text: /\$0\.012/
    end
    facts = css_select("dl.card > div").to_h { |fact| [ fact.at("dt").text, fact.at("dd").text ] }
    assert_equal [ "1", "0", "0" ], facts.values_at("Judged", "Passed", "Judge errors")

    get harbor.scorers_path
    assert_select "tr#scorer-#{scorer.id} td", text: /0%\s+of 1/
  end

  test "a site with no code of its own sees a proposal, applies one and dismisses another" do
    scorer = new_scorer(name: "Ran the tests")
    result = failure(scorer)
    drafted = Harbor::Run.create!(skill: "self-improvement", status: "ok")
    first = proposal(scorer:, run: drafted, regressions_addressed: "Runs pushed without tests.",
                     evidence: { "run_ids" => [ result.run_id ], "scorer_result_ids" => [ result.id ] })
    result.update!(proposal: first, reviewed_at: Time.current)
    second = proposal(summary: "Shout more", after: "BE CAREFUL.")

    get harbor.proposals_path
    assert_response :success
    assert_equal [ second.id, first.id ], css_select("tbody tr[id^=proposal-]").map { |row| row["id"].delete_prefix("proposal-").to_i }
    assert_select "tr#proposal-#{first.id}" do
      assert_select "a[href=?]", harbor.proposal_path(first), text: "Require a test run"
      assert_select "td", text: /writer · system prompt/
      assert_select "a[href=?]", harbor.scorer_path(scorer), text: "Ran the tests"
      assert_select "td", text: /1 runs/
    end

    get harbor.proposal_path(first)
    assert_response :success
    assert_select "h1", text: /Require a test run\s+proposed/
    assert_select "header p", text: /writer · system prompt\s+· from Ran the tests\s+· proposed by run ##{drafted.id}/
    assert_equal [ "  Be careful.", "+ Run the tests." ], css_select("pre span.block").map(&:text)
    assert_select "pre span.block.bg-pale-green", text: "+ Run the tests."
    assert_select "p", text: "Runs pushed without tests."
    assert_select "h2", text: "Evidence · 1 failed runs"
    assert_select "li a[href=?]", harbor.run_path(result.run_id), text: "run ##{result.run_id} · writer.review"
    assert_select "form[action=?] button[data-turbo-confirm]", harbor.apply_proposal_path(first), text: "Apply to writer"

    post harbor.apply_proposal_path(first)
    assert_redirected_to harbor.proposal_path(first)
    assert_equal "Applied to writer · system prompt. It takes effect on the agent's next run.", flash[:notice]
    assert_equal "Be careful.\nRun the tests.", @agent.reload.system_prompt
    assert_equal "applied", first.reload.status

    get harbor.proposal_path(first)
    assert_select "h1 .pill", text: "applied"
    assert_select "header p", text: /applied less than a minute ago/
    assert_select "[data-proposal-actions] form", count: 0

    post harbor.dismiss_proposal_path(second)
    assert_redirected_to harbor.proposals_path
    assert_equal "Dismissed.", flash[:notice]
    assert_equal "dismissed", second.reload.status
    assert_equal "Be careful.\nRun the tests.", @agent.reload.system_prompt

    get harbor.proposals_path
    assert_select "td", text: "No proposed proposals."
    assert_equal [ "Proposed 0", "Applied 1", "Dismissed 1" ], css_select("a.pill").map(&:text)
  end

  # --- the scorers list ---

  test "the list shows each scorer with what it judges, its judge, sample rate, pass rate and switch" do
    tests = new_scorer(name: "Ran the tests", description: "Before pushing.", sample_rate: 25, self_improvement: true, position: 0,
                       agent_keys: %w[writer], task_types: %w[review])
    off = new_scorer(name: "Review is specific", enabled: false, position: 1)
    Harbor::ScorerResult.create!(scorer: tests, run: agent_run, status: "ok", passed: true, classification: "pass", score: 1, scored_at: 1.hour.ago)
    Harbor::ScorerResult.create!(scorer: tests, run: agent_run, status: "ok", passed: false, classification: "fail", score: 0, scored_at: 40.days.ago)

    get harbor.scorers_path
    assert_response :success
    assert_select "title", text: "Scorers"
    assert_select "h1", text: "Scorers"
    assert_select "a[href=?]", harbor.new_scorer_path, text: "New scorer"
    assert_equal [ "Scorer", "Evaluates", "Judge", "Sample", "Pass rate · 30d", "Enabled" ], css_select("thead th").map(&:text)
    assert_equal [ tests.id, off.id ], css_select("tbody tr").map { |row| row["id"].delete_prefix("scorer-").to_i }
    assert_select "tr#scorer-#{tests.id}:not(.opacity-55)" do
      assert_select "a[href=?]", harbor.scorer_path(tests), text: "Ran the tests"
      assert_select "a.pill[href=?]", harbor.proposals_path, text: "self-improve"
      assert_select "p", text: "Before pushing."
      assert_select ".pill", text: "writer"
      assert_select "code.chip", text: "review"
      assert_select "td", text: /Quick/
      assert_select "td", text: /25%/
      assert_select "td", text: /100%\s+of 1/, message: "only the last 30 days count"
      assert_select "form[action=?] input[name=_method][value=patch]", harbor.toggle_scorer_path(tests)
      assert_select "button[aria-label='Disable Ran the tests']", text: "on"
    end
    assert_select "tr#scorer-#{off.id}.opacity-55" do
      assert_select "td", text: /every agent run/
      assert_select "td", text: /nothing judged/
      assert_select "button[aria-label='Enable Review is specific']", text: "off"
      assert_select "a.pill", count: 0
    end
    assert_equal [ "Scorers" ], current_page
  end

  test "a scorer is a card on a phone and a table row from lg up" do
    scorer = new_scorer
    get harbor.scorers_path
    assert_select "table.block.lg\\:table thead.hidden.lg\\:table-header-group", count: 1
    assert_select "tr#scorer-#{scorer.id}.grid.lg\\:table-row td.block.lg\\:table-cell", count: 6
    assert_select "tr#scorer-#{scorer.id} td span.lg\\:hidden", count: 5, message: "each fact carries its label when stacked"
  end

  test "the page explains the loop it is part of, with the Quality pages this site has, and how to start" do
    get harbor.scorers_path
    assert_select "section[data-quality-guide=scorers]", count: 1
    assert_equal [ [ "1 · After an agent finishes", "Scorers" ], [ "2 · When the same failure repeats", "Proposals" ] ], guide_parts,
                 "this site has no Review policy page, so the loop has two steps"
    assert_select "section[data-quality-guide] ol.grid.lg\\:grid-cols-2", count: 1
    assert_select "section[data-quality-guide] [aria-current=step]", text: "Scorers", count: 1
    assert_select "section[data-quality-guide] li a[href=?]", harbor.proposals_path, text: "Proposals"
    assert_select "section[data-quality-guide] details[open] summary", text: "How to use this page"
    assert_select "section[data-quality-guide] details ol li", count: 4
    assert_select "section[data-quality-guide] details a[href=?]", harbor.new_scorer_path, text: "Create a scorer"

    new_scorer
    get harbor.scorers_path
    assert_select "section[data-quality-guide] details[open]", count: 0, message: "folded once there is a scorer"

    Harbor::Setting.set!(:page_proposals, "false")
    get harbor.scorers_path
    assert_equal [ [ "1 · After an agent finishes", "Scorers" ] ], guide_parts, "a page switched off leaves the loop"
  end

  test "the list says when the site has no judge, and stops saying it when it has" do
    get harbor.scorers_path
    assert_select "[data-no-judge]", text: /No judge is configured/, count: 1
    Harbor.config.scorer_judge = ->(_) { "" }
    get harbor.scorers_path
    assert_select "[data-no-judge]", count: 0
  end

  test "a scorer is switched off and on from the list" do
    scorer = new_scorer(name: "Ran the tests")
    patch harbor.toggle_scorer_path(scorer)
    assert_redirected_to harbor.scorers_path
    assert_equal "Ran the tests disabled.", flash[:notice]
    assert_not scorer.reload.enabled?
    patch harbor.toggle_scorer_path(scorer)
    assert_equal "Ran the tests enabled.", flash[:notice]
    assert scorer.reload.enabled?
  end

  # --- a scorer's page ---

  test "a scorer's page shows what it is, its pass rate by week, its instructions, labels and recent verdicts" do
    scorer = new_scorer(name: "Ran the tests", description: "Before pushing.", sample_rate: 25, agent_keys: %w[writer], task_types: %w[review])
    passed = Harbor::ScorerResult.create!(scorer:, run: agent_run, status: "ok", passed: true, classification: "pass", score: 1,
                                          reasoning: "Ran them.", scored_at: 1.hour.ago)
    waiting = Harbor::ScorerResult.create!(scorer:, run: agent_run, status: "queued")
    broken = Harbor::ScorerResult.create!(scorer:, run: agent_run, status: "error", error: "the judge gave no verdict")

    get harbor.scorer_path(scorer)
    assert_response :success
    assert_select "title", text: "Ran the tests · Scorers"
    assert_select "h1", text: "Ran the tests"
    assert_select "header p", text: "Before pushing."
    assert_select "a[href=?]", harbor.edit_scorer_path(scorer), text: "Edit scorer"
    facts = css_select("dl.card > div").map { |fact| [ fact.at("dt").text, fact.at("dd").text ] }
    assert_equal [ %w[Judge Quick], [ "Sample rate", "25%" ], [ "Pass threshold", "1.0" ], %w[Status Enabled], [ "Evaluates", "writer, review" ],
                   %w[Judged 1], %w[Passed 1], [ "Judge errors", "1" ] ], facts
    assert_select ".spark .spark-col", count: 13, message: "twelve weeks back and this one"
    assert_select ".spark-tip b", text: "100"
    assert_equal [ "Judge instructions", "Classifications", "Recent verdicts" ], css_select("h2").map(&:text)
    assert_select "pre", text: "Did it run the tests?"
    assert_equal [ [ "pass", true ], [ "partial", false ], [ "fail", false ] ],
                 css_select("ul.card li .pill").map { |pill| [ pill.text, pill["class"].include?("bg-pale-green") ] }
    assert_equal [ "Run", "Verdict", "Reasoning", "Judge", "When" ], css_select("thead th").map(&:text)
    rows = css_select("tbody tr")
    assert_equal 3, rows.size
    assert_equal [ "pass · 1.0", "judging…", "error" ].sort, rows.map { |row| row.at_css(".pill").text }.sort
    assert_select "tbody td", text: "Ran them."
    assert_select "tbody td", text: "the judge gave no verdict"
    assert_select "tbody .pill[title='the judge gave no verdict']", text: "error"
    [ passed, waiting, broken ].each { |result| assert_select "tbody a[href=?]", harbor.run_path(result.run) }
    assert_equal [ "Scorers" ], current_page
  end

  test "a scorer nothing has judged says so" do
    scorer = new_scorer
    get harbor.scorer_path(scorer)
    assert_response :success
    assert_select "p", text: /Nothing judged yet/
    assert_select ".spark", count: 0
    assert_select "td", text: "No verdicts yet."
    assert_select "dd", text: "every agent run"
  end

  test "a scorer that doesn't exist is not found" do
    get harbor.scorer_path(0)
    assert_response :not_found
    get harbor.edit_scorer_path(0)
    assert_response :not_found
  end

  # --- the form ---

  test "the form has every field, with the aliases, agents and declared task types to pick from" do
    Harbor::Agent.create!(key: "editor")
    get harbor.new_scorer_path
    assert_response :success
    assert_select "title", text: "New scorer"
    assert_select "form[action=?][method=post]", harbor.scorers_path do
      assert_select "input[name='scorer[name]'][required]"
      assert_select "textarea[name='scorer[description]']"
      assert_equal [ "Choose an alias", "Quick" ], css_select("select[name='scorer[model_alias_id]'][required] option").map(&:text)
      assert_select "select[name='scorer[model_alias_id]'] option[selected]", count: 0
      assert_select "input[type=number][name='scorer[sample_rate]'][min='0'][max='100'][value='0']"
      assert_equal %w[editor writer], css_select("input[type=checkbox][name='scorer[agent_keys][]']").map { |box| box["value"] }
      assert_equal %w[review rebase], css_select("input[type=checkbox][name='scorer[task_types][]']").map { |box| box["value"] }
      assert_select "input[type=checkbox][checked][name^='scorer[agent_keys]'], input[type=checkbox][checked][name^='scorer[task_types]']", count: 0
      assert_select "textarea[name='scorer[judge_instructions]'][required]"
      assert_select "textarea[name='scorer[classifications_text]']", text: "pass=1.0\nfail=0.0"
      assert_select "input[type=number][name='scorer[pass_threshold]'][step='0.05'][value='1.0']"
      assert_select "input[type=checkbox][name='scorer[self_improvement]']:not([checked])"
      assert_select "label a[href=?]", harbor.proposals_path, text: "Proposals"
      assert_select "input[type=number][name='scorer[improvement_min_failures]'][min='1'][max='50'][value='25']"
      assert_select "input[type=number][name='scorer[improvement_max_age_days]'][min='1'][max='90'][value='7']"
      assert_select "input[type=checkbox][name='scorer[enabled]'][checked]"
      assert_select "input[type=submit][value='Save scorer']"
      assert_select "a[href=?]", harbor.scorers_path, text: "Cancel"
    end
    assert_select "a[href=?]", harbor.models_path, text: "Manage aliases"
    assert_equal [ "Scorers" ], current_page
  end

  test "editing shows what is saved and saves what is changed" do
    scorer = new_scorer(name: "Ran the tests", agent_keys: %w[writer], task_types: %w[review])
    get harbor.edit_scorer_path(scorer)
    assert_response :success
    assert_select "title", text: "Ran the tests · Scorers"
    assert_select "form[action=?] input[name=_method][value=patch]", harbor.scorer_path(scorer)
    assert_select "input[name='scorer[name]'][value='Ran the tests']"
    assert_select "input[name='scorer[agent_keys][]'][value=writer][checked]"
    assert_select "input[name='scorer[task_types][]'][value=review][checked]"
    assert_select "input[name='scorer[task_types][]'][value=rebase]:not([checked])"
    assert_select "textarea[name='scorer[classifications_text]']", text: "pass=1.0\npartial=0.5\nfail=0.0"

    patch harbor.scorer_path(scorer), params: { scorer: { name: "Ran the suite", judge_instructions: "Look harder.", model_alias_id: @alias.id,
                                                          sample_rate: 20, pass_threshold: 0.5, classifications_text: "yes=1\nno=0",
                                                          agent_keys: [ "" ], task_types: [ "", "rebase" ], enabled: "0",
                                                          improvement_min_failures: 5, improvement_max_age_days: 3 } }
    assert_redirected_to harbor.scorer_path(scorer)
    scorer.reload
    assert_equal [ "Ran the suite", "Look harder.", 20, 0.5, %w[yes no], [], %w[rebase], false, 5, 3 ],
                 [ scorer.name, scorer.judge_instructions, scorer.sample_rate, scorer.pass_threshold.to_f, scorer.labels, scorer.agent_keys,
                   scorer.task_types, scorer.enabled, scorer.improvement_min_failures, scorer.improvement_max_age_days ]
  end

  test "a scorer that can't be saved shows why and keeps what was typed" do
    assert_no_difference "Harbor::Scorer.count" do
      post harbor.scorers_path, params: { scorer: { name: "Broken", judge_instructions: "x", model_alias_id: @alias.id, classifications_text: "pass=high" } }
    end
    assert_response :unprocessable_entity
    assert_select "[role=alert]", text: "Classifications Scores must be numbers between 0 and 1."
    assert_select "input[name='scorer[name]'][value=Broken]"
    assert_select "textarea[name='scorer[classifications_text]']", text: "pass=high"

    post harbor.scorers_path, params: { scorer: { name: "", judge_instructions: "", model_alias_id: "", classifications_text: "pass=1" } }
    assert_response :unprocessable_entity
    assert_select "[role=alert]", text: /Name can't be blank/
    assert_select "[role=alert]", text: /Judge instructions can't be blank/
    assert_select "[role=alert]", text: /Model alias must exist/

    scorer = new_scorer
    patch harbor.scorer_path(scorer), params: { scorer: { name: scorer.name, sample_rate: 500, classifications_text: "pass=1" } }
    assert_response :unprocessable_entity
    assert_select "form[action=?]", harbor.scorer_path(scorer)
    assert_equal 0, scorer.reload.sample_rate
  end

  test "a host's scorer class decides the task types offered and what a new scorer starts with" do
    Harbor.config.scorer_class = HostScorer.name
    get harbor.new_scorer_path
    assert_equal %w[review rebase automation], css_select("input[name='scorer[task_types][]']").map { |box| box["value"] }
    assert_select "select[name='scorer[model_alias_id]'] option[selected]", text: "Quick"
    post harbor.scorers_path, params: { scorer: { name: "Host's", judge_instructions: "x", model_alias_id: @alias.id, classifications_text: "pass=1",
                                                  task_types: [ "automation" ] } }
    assert_instance_of HostScorer, Harbor.scorer_class.sole
  end

  test "a host says in its own words what self-improvement does" do
    host_views "overrides"
    get harbor.new_scorer_path
    assert_select "label [data-host-note]", text: "Draft fixes to the agent or the handbook.", count: 1
    assert_select "label a[href=?]", harbor.proposals_path, count: 0
  end

  # --- scores on a run's page ---

  test "a run's page shows its scores between its details and its log, with a way to judge it now" do
    Harbor.config.log_path = ->(run) { "runs/#{run.id}.log" }
    scorer = new_scorer(name: "Ran the tests")
    other = new_scorer(name: "Stayed on task")
    new_scorer(name: "For rebases", task_types: %w[rebase])
    run = agent_run
    File.write(Harbor::LiveLog.absolute(run.live_log_path).tap { |path| FileUtils.mkdir_p(File.dirname(path)) }, "a line\n")
    get harbor.run_path(run)
    assert_response :success
    assert_equal %w[run-details run-scores run-live-log run-payloads],
                 css_select("#run-details, #run-scores, #run-live-log, #run-payloads").map { |node| node["id"] }
    assert_select "#run-scores h2", text: /Scores/
    assert_select "#run-scores p", text: "Not judged yet — 2 scorer(s) apply."
    assert_equal [ "every applicable scorer", "Ran the tests", "Stayed on task" ],
                 css_select("#run-scores form[action='#{harbor.score_run_path(run)}'] select[name=scorer_id] option").map(&:text)
    assert_select "#run-scores input[type=submit][value='Score now']"
    assert_select "[data-controller='harbor--poll']", count: 0

    proposed = proposal(scorer:)
    judge = Harbor::Run.create!(parent_run_id: run.id, skill: "scorer", status: "ok")
    done = Harbor::ScorerResult.create!(scorer:, run:, judge_run: judge, status: "ok", passed: true, classification: "pass", score: 1,
                                        reasoning: "Ran them.", scored_at: 1.hour.ago, proposal: proposed)
    failed = Harbor::ScorerResult.create!(scorer: other, run:, status: "error", error: "the judge gave no verdict")
    get harbor.run_path(run)
    assert_select "#run-scores li##{ActionView::RecordIdentifier.dom_id(done)}" do
      assert_select ".pill.bg-pale-green", text: "pass · 1.0"
      assert_select "span.meta", text: /pass · about 1 hour ago/
      assert_select "a[href=?]", harbor.run_path(judge), text: "judge run ##{judge.id}"
      assert_select "a[href=?]", harbor.proposal_path(proposed), text: "proposal ##{proposed.id}"
      assert_select "form[action=?] button", harbor.score_run_path(run, scorer_id: scorer.id), text: "Re-score"
      assert_select "details[data-controller='harbor--details'] p", text: "Ran them."
    end
    assert_select "#run-scores li##{ActionView::RecordIdentifier.dom_id(failed)}" do
      assert_select ".pill.bg-pale-yellow", text: "error"
      assert_select "span.meta", text: "the judge gave no verdict"
    end
    assert_select "#run-delegated-runs", count: 0, message: "a judge isn't listed among the runs it delegated"
  end

  test "a run nothing can score has no scores section, and one judged before still shows what was said" do
    loader = Harbor::Run.create!(loader: "catalog-import", status: "ok")
    get harbor.run_path(loader)
    assert_select "#run-scores", count: 0

    scorer = new_scorer
    child = agent_run(parent_run_id: agent_run.id)
    Harbor::ScorerResult.create!(scorer:, run: child, status: "ok", passed: true, classification: "pass", score: 1, scored_at: 1.hour.ago)
    get harbor.run_path(child)
    assert_select "#run-scores .pill", text: "pass · 1.0"
    assert_select "#run-scores form", count: 0, message: "it can't be scored again"

    get harbor.run_path(agent_run)
    assert_select "#run-scores p", text: "Not judged yet — 1 scorer(s) apply."
    scorer.update!(enabled: false)
    get harbor.run_path(agent_run)
    assert_select "#run-scores p", text: "Not judged yet."
    assert_select "#run-scores form", count: 0
  end

  test "scoring by hand claims the run once, and the page keeps refreshing until the verdict is in" do
    scorer = new_scorer(name: "Ran the tests")
    run = agent_run
    assert_enqueued_with(job: Harbor::Scorers::EvaluateJob,
                         args: [ { scorer_id: scorer.id, run_id: run.id, trigger_source: "manual", triggered_by_user_id: nil } ]) do
      post harbor.score_run_path(run, scorer_id: scorer.id)
    end
    assert_redirected_to harbor.run_path(run)
    assert Harbor::ScorerResult.find_by!(scorer:, run:).queued?, "the claim is made before the job runs"

    get harbor.run_path(run)
    assert_select "#run-scores .pill", text: "judging…"
    assert_select "[data-controller='harbor--poll'][data-harbor--poll-interval-value='5']", count: 1

    assert_no_enqueued_jobs(only: Harbor::Scorers::EvaluateJob) { post harbor.score_run_path(run, scorer_id: scorer.id) }
    assert_equal "Run ##{run.id} is already being judged by Ran the tests — the verdict appears here shortly.", flash[:notice]
    assert_equal 1, Harbor::ScorerResult.where(run:).count
  end

  test "every applicable scorer judges a run scored without naming one" do
    first = new_scorer(name: "A", position: 0)
    second = new_scorer(name: "B", position: 1)
    new_scorer(name: "C", task_types: %w[rebase])
    run = agent_run
    assert_enqueued_jobs(2, only: Harbor::Scorers::EvaluateJob) { post harbor.score_run_path(run) }
    assert_equal "Judging run ##{run.id} with A and B — the verdict appears here shortly.", flash[:notice]
    assert_equal [ first.id, second.id ], Harbor::ScorerResult.where(run:).order(:scorer_id).pluck(:scorer_id)
  end

  test "a run that can't be scored, or that no scorer applies to, says so" do
    scorer = new_scorer(task_types: %w[rebase])
    run = agent_run
    assert_no_enqueued_jobs { post harbor.score_run_path(run) }
    assert_redirected_to harbor.run_path(run)
    assert_equal "No enabled scorer applies to this run.", flash[:alert]

    queued = agent_run(status: "queued")
    assert_no_enqueued_jobs { post harbor.score_run_path(queued, scorer_id: scorer.id) }
    assert_equal "Only a finished, top-level agent run with a transcript can be scored.", flash[:alert]
    assert_equal 0, Harbor::ScorerResult.count
  end

  # --- the proposals list ---

  test "the list shows proposals of one status, newest first, with counts of each" do
    scorer = new_scorer(name: "Ran the tests")
    old = proposal(summary: "First\nwith more below", scorer:, evidence: { "run_ids" => [ 1, 2 ] }, created_at: 2.days.ago)
    recent = proposal(summary: "x" * 200, target_kind: "agent_document", document_path: "memory/testing.md")
    applied = proposal(summary: "Applied one", status: "applied", applied_at: 1.hour.ago)

    get harbor.proposals_path
    assert_response :success
    assert_select "title", text: "Proposals"
    assert_select "h1", text: "Proposals"
    assert_select "header p", text: /Suggested fixes for mistakes an agent keeps making/
    assert_equal [ "Proposed 2", "Applied 1", "Dismissed 0" ], css_select("a.pill").map(&:text)
    assert_select "a.pill.bg-ink[href=?]", harbor.proposals_path(status: "proposed"), text: "Proposed 2"
    assert_equal [ "Proposal", "Target", "Scorer", "Evidence", "When" ], css_select("thead th").map(&:text)
    assert_equal [ recent.id, old.id ], css_select("tbody tr").map { |row| row["id"].delete_prefix("proposal-").to_i }
    assert_select "tr#proposal-#{recent.id}" do
      assert_select "a[href=?]", harbor.proposal_path(recent), text: "#{'x' * 137}..."
      assert_select "td", text: /writer · memory\/testing\.md/
      assert_select "td span.meta", text: "—"
      assert_select "td", text: /0 runs/
    end
    assert_select "tr#proposal-#{old.id}" do
      assert_select "a[href=?]", harbor.scorer_path(scorer), text: "Ran the tests"
      assert_select "td", text: /2 runs/
      assert_select "td", text: /2 days ago/
    end
    assert_select "tr#proposal-#{applied.id}", count: 0
    assert_equal [ "Proposals" ], current_page

    get harbor.proposals_path(status: "applied")
    assert_equal [ applied.id ], css_select("tbody tr").map { |row| row["id"].delete_prefix("proposal-").to_i }
    assert_select "a.pill.bg-ink", text: "Applied 1"
    get harbor.proposals_path(status: "nonsense")
    assert_select "a.pill.bg-ink", text: "Proposed 2"
    get harbor.proposals_path(status: "dismissed")
    assert_select "td", text: "No dismissed proposals."
  end

  test "a proposal is a card on a phone and a table row from lg up" do
    made = proposal
    get harbor.proposals_path
    assert_select "table.block.lg\\:table thead.hidden.lg\\:table-header-group", count: 1
    assert_select "tr#proposal-#{made.id}.grid.lg\\:table-row td.block.lg\\:table-cell", count: 5
  end

  test "the proposals page explains the loop and how to use it, unfolded while there is nothing to read" do
    get harbor.proposals_path
    assert_equal [ [ "1 · After an agent finishes", "Scorers" ], [ "2 · When the same failure repeats", "Proposals" ] ], guide_parts
    assert_select "section[data-quality-guide=proposals] [aria-current=step]", text: "Proposals", count: 1
    assert_select "section[data-quality-guide] li a[href=?]", harbor.scorers_path, text: "Scorers"
    assert_select "section[data-quality-guide] details[open] ol li", count: 4
    assert_select "section[data-quality-guide] details a[href=?]", harbor.scorers_path, text: "scorer"
    proposal
    get harbor.proposals_path
    assert_select "section[data-quality-guide] details[open]", count: 0
    get harbor.proposals_path(status: "applied")
    assert_select "section[data-quality-guide] details[open]", count: 0, message: "only the proposed list starts unfolded"
  end

  test "the check is run from the page when the site has a drafter, as a run of its own" do
    get harbor.proposals_path
    assert_select "form[action=?]", harbor.check_proposals_path, count: 0, message: "nothing to hand failures to"

    Harbor.config.proposal_drafter = ->(**) { }
    get harbor.proposals_path
    assert_select "form[action=?][method=post] button", harbor.check_proposals_path, text: "Run the check now"

    assert_difference "Harbor::Run.count" do
      assert_enqueued_with(job: Harbor::Proposals::CheckJob) { post harbor.check_proposals_path }
    end
    run = Harbor::Run.last
    assert_redirected_to harbor.run_path(run)
    assert_equal [ "self-improvement-check", "manual", "queued" ], [ run.skill, run.trigger_source, run.status ]
    assert_equal [ run.id ], enqueued_jobs.last["arguments"]
    perform_enqueued_jobs
    assert_equal "skipped", run.reload.status, "no scorer has self-improvement on"
    get harbor.run_path(run)
    assert_select "#run-error pre", text: /No enabled scorer has self-improvement switched on/
  end

  test "a host words the page its own way and starts the check its own way" do
    host_views "overrides"
    Harbor.config.proposal_drafter = ->(**) { }
    get harbor.proposals_path
    assert_select "header p", text: "Fixes for the handbook and for the agents that write it."
    assert_select "header a[data-host-check]", text: "Open the schedule", count: 1
    assert_select "form[action=?]", harbor.check_proposals_path, count: 0
    assert_equal [ "The check runs at noon." ], css_select("section[data-quality-guide=proposals] details ol li").map(&:text)
  end

  # --- a proposal's page ---

  test "a proposal's page shows the change line by line, what it addresses and the runs behind it" do
    scorer = new_scorer(name: "Ran the tests")
    results = 2.times.map { failure(scorer) }
    made = proposal(summary: "Require a test run\nAnd say why.", before: "Be careful.\nWork fast.", after: "Be careful.\nRun the tests.",
                    evidence: { "scorer_result_ids" => results.map(&:id) })
    get harbor.proposal_path(made)
    assert_response :success
    assert_select "title", text: "Proposal ##{made.id}"
    assert_select "a[href=?]", harbor.proposals_path, text: "All proposals"
    assert_select "h1", text: /\ARequire a test run\s+proposed\z/
    assert_select "h1 .pill.bg-pale-blue", text: "proposed"
    assert_select "p.whitespace-pre-wrap", text: /\ARequire a test run\s+And say why\.\z/
    assert_equal [ "The change", "Evidence · 2 failed runs" ], css_select("h2").map { |h2| h2.text.squish }
    assert_equal [ [ "  Be careful.", "text-body" ], [ "− Work fast.", "bg-pale-red" ], [ "+ Run the tests.", "bg-pale-green" ] ],
                 css_select("pre span.block").map { |line| [ line.text, line["class"].split[1] ] }
    assert_select "ul.card li", count: 2, message: "with no results linked, the ones the evidence names are shown"
    assert_select "ul.card li .pill.bg-pale-red", text: "fail · 0.0", count: 2
    assert_select "ul.card li p.meta", text: "No test run after the last edit.", count: 2
    assert_equal [ "Proposals" ], current_page
  end

  test "a proposal says when it changes nothing, has nothing behind it, or its target has changed since" do
    same = proposal(before: "Be careful.", after: "Be careful.")
    get harbor.proposal_path(same)
    assert_select "p.meta", text: "No line changed."
    assert_select "li", text: "No scorer results linked."
    assert_select "p.whitespace-pre-wrap", count: 0, message: "a one-line summary is the heading only"

    stale = proposal(before: "Something older.")
    get harbor.proposal_path(stale)
    assert_select "[data-proposal-actions] .pill", text: /the current text changed since this was proposed/
    assert_select "form[action=?]", harbor.apply_proposal_path(stale), count: 0
    assert_select "form[action=?] button", harbor.dismiss_proposal_path(stale), text: "Dismiss"

    post harbor.apply_proposal_path(stale)
    assert_redirected_to harbor.proposal_path(stale)
    assert_equal "writer · system prompt changed since this proposal was made — dismiss it and run the check again", flash[:alert]
    assert_equal "proposed", stale.reload.status
  end

  test "a proposal for an agent that has gone can only be dismissed" do
    gone = proposal(agent_key: "nobody")
    get harbor.proposal_path(gone)
    assert_response :success
    assert_select "[data-proposal-actions] form", count: 1
    assert_select "form[action=?]", harbor.dismiss_proposal_path(gone)
    post harbor.apply_proposal_path(gone)
    assert_equal "only agent prompt or document proposals apply here", flash[:alert]
  end

  test "a host's proposal class names who applied one" do
    Harbor.config.proposal_class = HostProposal.name
    applied = proposal(status: "applied", applied_at: 2.hours.ago, applied_by_user_id: 7)
    get harbor.proposal_path(applied)
    assert_select "header p", text: /applied about 2 hours ago by user #7/
  end

  test "a proposal of a host's own kind is listed and shown, with nothing of Harbor's to apply" do
    register_handbook
    page = proposal(target_kind: "handbook_page", document_path: "testing", before: nil, after: "Run the tests.")
    get harbor.proposals_path
    assert_select "tr#proposal-#{page.id} td", text: /handbook · testing/
    get harbor.proposal_path(page)
    assert_response :success
    assert_select "header p", text: /handbook · testing/
    assert_equal [ "Evidence · 0 failed runs" ], css_select("h2").map { |h2| h2.text.squish }, "there is no text of Harbor's to diff"
    assert_select "[data-proposal-actions] form", count: 1
    assert_select "form[action=?]", harbor.dismiss_proposal_path(page)
  end

  test "a host adds its own marks, buttons, sections and view of the change for its own kind" do
    register_handbook
    host_views "extras"
    page = proposal(target_kind: "handbook_page", document_path: "testing", before: nil, after: "Run the tests.")
    plain = proposal

    get harbor.proposals_path
    assert_select "tr#proposal-#{page.id} [data-host-badge='#{page.id}']", text: "handbook", count: 1
    assert_select "tr#proposal-#{plain.id} [data-host-badge]", count: 0

    get harbor.proposal_path(page)
    assert_select "[data-proposal-actions] a[data-host-action][href='/handbook/testing']", text: "Edit the page", count: 1
    assert_select "[data-host-extras='#{page.id}']", text: "Handbook editors were told.", count: 1
    assert_select "[data-host-change='#{page.id}'] pre", text: "Run the tests.", count: 1
    order = css_select("[data-proposal-actions], [data-host-extras], [data-host-change], section h2").map { |node| node["data-host-extras"] ? "extras" : node.name == "h2" ? node.text.squish : node.attributes.keys.grep(/data-/).first }
    assert_equal [ "data-proposal-actions", "extras", "data-host-change", "The page as proposed", "Evidence · 0 failed runs" ], order

    get harbor.proposal_path(plain)
    assert_select "[data-host-action]", count: 0
    assert_select "[data-host-change]", count: 0, message: "Harbor's own kinds keep Harbor's diff"
    assert_select "h2", text: /The change/
    assert_select "[data-host-extras='#{plain.id}']", count: 1
  end

  test "a proposal that doesn't exist is not found" do
    get harbor.proposal_path(0)
    assert_response :not_found
    post harbor.apply_proposal_path(0)
    assert_response :not_found
  end

  # --- switches and the menu ---

  test "each page is switched off on its own, and a run's scores stay" do
    scorer = new_scorer
    made = proposal
    Harbor::Setting.set!(:page_scorers, "false")
    [ harbor.scorers_path, harbor.scorer_path(scorer), harbor.new_scorer_path ].each do |path|
      get path
      assert_response :not_found
    end
    patch harbor.toggle_scorer_path(scorer)
    assert_response :not_found
    get harbor.proposals_path
    assert_response :success
    assert_not_includes css_select("[data-harbor-nav] a").map { |a| a.text.strip }, "Scorers"

    Harbor::Setting.set!(:page_proposals, "false")
    [ harbor.proposals_path, harbor.proposal_path(made) ].each do |path|
      get path
      assert_response :not_found
    end
    post harbor.apply_proposal_path(made)
    assert_response :not_found
    assert_equal "proposed", made.reload.status

    get harbor.run_path(agent_run)
    assert_select "#run-scores", count: 1
  end

  test "the menu's Quality group holds both pages, at Harbor's own addresses" do
    get harbor.scorers_path
    quality = css_select("[data-harbor-nav] [data-nav-group=quality] a").map { |a| [ a.text.strip, a["href"] ] }
    assert_equal [ [ "Scorers", "/factory/scorers" ], [ "Proposals", "/factory/proposals" ] ], quality
  end

  test "someone logged out is sent to log in" do
    delete "/logout"
    [ harbor.scorers_path, harbor.proposals_path ].each do |path|
      get path
      assert_redirected_to "/login"
    end
    post harbor.score_run_path(agent_run)
    assert_redirected_to "/login"
  end
end
