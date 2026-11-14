require "test_helper"

# The Review policy pages: the rules, a rule's page and form with its
# versions, a round's page with its checks, and the dashboard. What a site
# with no code of its own gets, and each place a host can fill.
class HarborReviewPagesTest < ActionDispatch::IntegrationTest
  include HarborTestConfig
  include ActiveJob::TestHelper

  HOST_VIEWS = File.expand_path("fixtures/host_views/extras", __dir__)
  CONFIG = %i[review_rule_class review_rule_version_class review_document_schema review_pull_request_url
              review_rule_preview review_rule_preview_sample review_cost].freeze
  CONTROLLERS = [ Harbor::ReviewsController, Harbor::ReviewRulesController, Harbor::ReviewRoundsController,
                  Harbor::ReviewDashboardsController ].freeze

  setup do
    Harbor::Reviews.reset!
    @review_config = CONFIG.index_with { |name| Harbor.config.public_send(name) }
    @view_paths = CONTROLLERS.index_with(&:view_paths)
    [ Harbor::ReviewFeedback, Harbor::ReviewEscape, Harbor::ReviewCheckRun, Harbor::ReviewRound,
      Harbor::ReviewRuleVersion, Harbor::ReviewRule, Harbor::Run ].each(&:delete_all)
    post "/login", params: { name: "Sam Settings" }
  end

  teardown do
    Harbor::Reviews.reset!
    @review_config.each { |name, value| Harbor.config.public_send("#{name}=", value) }
    @view_paths.each { |controller, paths| controller.view_paths = paths }
  end

  # What a host does: a views folder of its own, looked in before Harbor's.
  def host_views = CONTROLLERS.each { |controller| controller.prepend_view_path(HOST_VIEWS) }

  RISK = { "label" => "risk: billing", "description" => "Money moves.", "detector" => { "paths" => [ "(\\A|/)app/billing/" ] } }.freeze
  CHECK = { "description" => "No page gets slower.", "mitigates" => [ "billing" ], "kind" => "command",
            "run" => { "command" => "bin/page-budgets --json" }, "outputs" => [ { "name" => "pages_over", "type" => "list" } ],
            "pass_when" => { "path" => "outputs.pages_over", "op" => "blank" },
            "then" => [ { "when" => { "path" => "outputs.pages_over", "op" => "present" }, "action" => "signoff", "signoff" => "budget" } ] }.freeze
  SIGNOFF = { "who" => [ "sam" ], "message" => "Approve the budget", "when" => { "risks" => [ "billing" ] } }.freeze

  def rule(kind, key, name, definition, **attrs)
    Harbor::ReviewRule.new(kind:, key:, name:, **attrs).tap do |record|
      _, errors = record.save_definition!(definition)
      raise errors.join("; ") if errors.any?
    end
  end

  def policy
    @risk = rule("risk", "billing", "Billing", RISK)
    @check = rule("check", "page-budgets", "Page budgets", CHECK)
    @signoff = rule("signoff", "budget", "Budget owner", SIGNOFF)
  end

  def round(**attrs) = Harbor::ReviewRound.create!({ repo: "acme/shop", pr_number: 5, head_sha: "abcdef1234" }.merge(attrs))

  def create_rule(definition, **fields)
    post harbor.review_rules_path, params: { review_rule: { kind: "risk", key: "billing", repo: "*", name: "Billing" }.merge(fields),
                                             definition: definition.is_a?(String) ? definition : definition.to_json }
  end

  # --- a site with no code of its own ---

  test "with no rules the page explains the policy, offers each kind of rule and says there are no rounds" do
    get harbor.reviews_path
    assert_response :success
    assert_select "title", text: "Review policy"
    assert_select "h1", text: "Review policy"
    assert_select "a[href=?]", harbor.new_review_rule_path(kind: "risk"), text: "+ Risk"
    assert_select "a[href=?]", harbor.new_review_rule_path(kind: "check"), text: "+ Check"
    assert_select "a[href=?]", harbor.new_review_rule_path(kind: "signoff"), text: "+ Sign-off"
    assert_select "a[href=?]", harbor.review_dashboard_path, text: "Dashboard"
    assert_select "p", text: "No review rounds yet."
    assert_select "section[data-quality-guide=reviews]", count: 1
    assert_select "[data-harbor-menu] a.current", text: "Review policy"
  end

  test "the form for a new rule starts in shadow with a definition that can be saved as it is" do
    %w[risk check signoff].each do |kind|
      get harbor.new_review_rule_path(kind:)
      assert_response :success
      assert_select "select[name='review_rule[kind]'] option[selected]", text: kind
      assert_select "select[name='review_rule[mode]'] option[selected]", text: "shadow"
      assert_select "input[name='review_rule[repo]'][value='*']"
      assert_select "input[type=submit][value='Create in shadow']"
      definition = JSON.parse(css_select("textarea[name=definition]").first.text)
      assert_empty Harbor::Reviews::RuleDefinition.errors(kind, Harbor::Reviews::RuleDefinition.normalize(kind, definition)), kind
    end
    assert_select "p", text: /Preview/, count: 0
    get harbor.new_review_rule_path(kind: "hunch")
    assert_select "select[name='review_rule[kind]'] option[selected]", text: "check"
  end

  test "a rule is written on the page, edited, and its versions are listed and rolled back" do
    assert_difference("Harbor::ReviewRule.count", 1) { create_rule(RISK) }
    made = Harbor::ReviewRule.find_by!(key: "billing")
    assert_equal [ "risk", "shadow", "*", 1 ], [ made.kind, made.mode, made.repo, made.version_number ]
    assert_redirected_to harbor.review_rule_path(made)
    follow_redirect!
    assert_select "[data-notice]", text: "Saved v1 in shadow mode."
    assert_select "h1", text: /Billing\s+v1/
    assert_select "p", text: "Money moves."
    assert_select "code", text: "risk: billing"
    assert_select "form[action=?]", harbor.preview_review_rule_path(made), count: 0
    assert_select "span.pill", text: "current", count: 1

    get harbor.edit_review_rule_path(made)
    assert_response :success
    assert_select "select[name='review_rule[kind]']", count: 0
    assert_select "input[name='review_rule[name]'][value=Billing]"
    assert_equal made.definition, JSON.parse(css_select("textarea[name=definition]").first.text)
    assert_select "input[type=submit][value^='Preview']", count: 0

    patch harbor.review_rule_path(made), params: { review_rule: { name: "Billing and refunds", mode: "live", key: "ignored", kind: "check" },
                                                   definition: RISK.merge("description" => "Money moves, both ways.").to_json }
    assert_redirected_to harbor.review_rule_path(made)
    assert_equal [ "Billing and refunds", "live", "billing", "risk", 2 ],
                 [ made.reload.name, made.mode, made.key, made.kind, made.version_number ]
    follow_redirect!
    assert_select "[data-notice]", text: "Saved v2."
    assert_select "section span.font-medium", text: "v2"
    assert_select "section span.font-medium", text: "v1"
    assert_select "form[action=?]", harbor.rollback_review_rule_path(made, number: 1), count: 1
    assert_select "form[action=?]", harbor.rollback_review_rule_path(made, number: 2), count: 0

    # Saving the same definition again changes the name or mode, not the version.
    patch harbor.review_rule_path(made), params: { review_rule: { name: "Billing", mode: "off" }, definition: made.definition.to_json }
    assert_equal [ "Billing", "off", 2 ], [ made.reload.name, made.mode, made.version_number ]

    post harbor.rollback_review_rule_path(made, number: 1)
    assert_redirected_to harbor.review_rule_path(made)
    assert_equal [ 3, "Money moves." ], [ made.reload.version_number, made.definition["description"] ]
    follow_redirect!
    assert_select "[data-notice]", text: "Rolled back to v1 (saved as a new version)."
  end

  test "a definition that isn't JSON, or says something a rule can't, is shown again with why" do
    assert_no_difference("Harbor::ReviewRule.count") { create_rule("{nope") }
    assert_response :unprocessable_entity
    assert_select "[data-alert]", text: /\AThat isn't valid JSON/
    assert_select "textarea[name=definition]", text: "{nope"

    assert_no_difference("Harbor::ReviewRule.count") { create_rule({ "label" => "", "detector" => { "builtin" => "risk: nope" } }) }
    assert_response :unprocessable_entity
    assert_select "[data-alert]", text: 'a risk needs a label; unknown builtin detector "risk: nope"'

    assert_no_difference("Harbor::ReviewRule.count") { create_rule(RISK, key: "Not A Slug") }
    assert_response :unprocessable_entity
    assert_select "[data-alert]", text: "Key is invalid"

    made = rule("risk", "billing", "Billing", RISK)
    patch harbor.review_rule_path(made), params: { review_rule: { name: "Billing", mode: "off" }, definition: { "label" => "x" }.to_json }
    assert_response :unprocessable_entity
    assert_select "[data-alert]", text: "a risk needs a detector"
    assert_equal [ 1, "live" ], [ made.reload.version_number, made.mode ]
  end

  test "the policy page reads risk by risk: its checks, its sign-offs and its gaps" do
    policy
    uncovered = rule("risk", "copy", "Copy", RISK.merge("label" => "risk: copy"), mode: "shadow")
    every = rule("check", "ci-green", "CI", { "mitigates" => [ "*" ], "kind" => "ci", "run" => { "job" => "*" } })

    get harbor.reviews_path
    assert_response :success
    assert_select "#risk-#{@risk.id}" do
      assert_select "a[href=?]", harbor.review_rule_path(@risk), text: "Billing"
      assert_select "span.pill", text: "live"
      assert_select "a[href=?]", harbor.review_rule_path(@check), text: "Page budgets"
      assert_select "span.text-faint", text: "· command · blocking"
      assert_select "a[href=?]", harbor.review_rule_path(@signoff), text: "Budget owner"
      assert_select "span.pill", text: "gap: no check", count: 0
    end
    assert_select "#risk-#{uncovered.id}" do
      assert_select "span.pill", text: "shadow"
      assert_select "span.pill", text: "gap: no check"
    end
    assert_select "a[href=?]", harbor.review_rule_path(every), text: "CI"
    assert_select "span.text-faint", text: "· sam · Approve the budget"
    assert_equal "/factory/reviews", harbor.reviews_path
    get harbor.review_rules_path
    assert_redirected_to harbor.reviews_path
  end

  test "a rule's page says what the rule says, for each kind" do
    policy
    get harbor.review_rule_path(@check)
    assert_response :success
    assert_select "title", text: "Page budgets · Review policy"
    assert_select "p", text: /Mitigates\s+billing/
    assert_select "p", text: /Runs\s+command · bin\/page-budgets --json/
    assert_select "p", text: /Passes when\s+outputs.pages_over blank/
    assert_select "p", text: /Gate\s+blocking · Stage\s+evidence/
    assert_select "p", text: /Outputs\s+pages_over \(list\)/
    assert_select "p", text: /Then\s+outputs.pages_over present → signoff\s+budget/
    assert_select "p", text: /No results yet/

    get harbor.review_rule_path(@signoff)
    assert_select "p", text: /Who\s+sam/
    assert_select "p", text: /Message\s+Approve the budget/
    assert_select "h2", text: "Recent results", count: 0
  end

  test "a round the site recorded shows its checks, why they were asked for, its sign-offs and the review" do
    policy
    shadow = rule("check", "decisions", "Decision records", CHECK.merge("stage" => "after_approval"), mode: "shadow")
    check_run = Harbor::Run.create!(skill: "reviews.check", status: "ok", cost_usd_actual: 0.4)
    recorded = round(phase: "published", finished_at: Time.current, trigger_source: "manual",
                     risks: [ { "key" => "billing", "reasons" => [ "app/billing/refund.rb" ] } ], gaps: [ "copy" ],
                     gate: { "result" => "passed", "blocking_failures" => [] },
                     signoffs: [ { "key" => "budget", "name" => "Budget owner", "who" => [ "sam" ], "message" => "Approve the budget",
                                   "status" => "approved", "by" => "sam", "how" => "approved" } ],
                     review: { "verdict" => "APPROVE", "tldr" => [ "Refunds are rounded once." ], "why" => "Small and covered.",
                               "findings" => [ { "severity" => "nit", "title" => "Name the constant", "path" => "app/billing/refund.rb", "line" => 12 } ] })
    recorded.check_runs.create!(review_rule: @check, check_key: "page-budgets", check_version: 1, status: "passed", summary: "0 pages over",
                                run: check_run, routed: [ { "action" => "signoff", "signoff" => "budget" } ])
    recorded.check_runs.create!(review_rule: shadow, check_key: "decisions", check_version: 1, status: "failed", mode: "shadow",
                                stage: "after_approval")

    get harbor.review_round_path(recorded)
    assert_response :success
    assert_select "title", text: "PR #5 round 1 · Review policy"
    assert_select "h1", text: /PR #5\s+· round 1/
    assert_select "h1 a", count: 0
    assert_select "header p", text: /abcdef1\s+· published\s+· started by manual\s+· \$0\.40 · 0 min · 2 checks/
    assert_select "[data-controller='harbor--poll']", count: 0
    assert_select "#round-progress" do
      assert_select "h2", text: "Approved"
      assert_select "p", text: "100%"
      assert_select "#check-page-budgets" do
        assert_select "span", text: "✅"
        assert_select "span.font-medium", text: "Page budgets"
        assert_select "span.text-soft", text: "· 0 pages over"
        assert_select "a[href=?]", harbor.run_path(check_run), text: "run"
        assert_select "span.text-faint", text: "→ signoff budget"
        assert_select "span.pill", count: 0
      end
      assert_select "#check-decisions" do
        assert_select "span", text: "❌"
        assert_select "span.text-soft", text: "· failed"
        assert_select "span.pill", text: "shadow"
        assert_select "span.pill", text: "after approval"
      end
    end
    assert_select "div", text: /billing\s+← app\/billing\/refund.rb/
    assert_select "p", text: /gaps\s+copy/
    assert_select "div", text: /Budget owner\s+· sam · Approve the budget · approved by sam/
    assert_select "[data-review-verdict]", text: "Approve"
    assert_select "li", text: "Refunds are rounded once."
    assert_select "[data-review-findings] li", text: /nit\s+Name the constant\s+app\/billing\/refund.rb:12/
    assert_select "summary", text: "Document (harbor.review/v1)"

    get harbor.review_round_path(recorded, format: :json)
    document = JSON.parse(response.body)
    assert_equal [ "harbor.review/v1", recorded.id, "published", %w[page-budgets decisions] ],
                 [ document["schema"], document["round_id"], document["phase"], document["checks"].map { |c| c["key"] } ]

    # The round is listed on the policy page and under the check that ran in it.
    get harbor.reviews_path
    assert_select "a[href=?]", harbor.review_round_path(recorded), text: /#5\s+round 1 · abcdef1\s+published\s+APPROVE/
    get harbor.review_rule_path(@check)
    assert_select "p", text: /100% passed/
    assert_select "a[href=?]", harbor.review_round_path(recorded), text: "#5 round 1"
    get harbor.review_rule_path(shadow)
    assert_select "p", text: /0% passed\s+· in shadow, would have blocked 1 of 1/
  end

  test "a round still under way refreshes itself and says there is nothing to check when nothing applies" do
    open = round(phase: "evidence")
    get harbor.review_round_path(open)
    assert_response :success
    assert_select "[data-controller='harbor--poll'][data-harbor--poll-interval-value='5']"
    assert_select "#round-progress h2", text: "No evidence needed"
    assert_select "p", text: "No checks apply to this change."
    assert_select "h2", text: "Review", count: 0
    assert_select "p", text: "None."
  end

  test "the dashboard counts rounds, what the checks cost, what was reused, precision and escapes" do
    policy
    run = Harbor::Run.create!(skill: "reviews.check", status: "ok", cost_usd_actual: 2.0)
    first = round(phase: "published", created_at: 3.hours.ago, finished_at: 1.hour.ago, review: { "verdict" => "APPROVE" },
                  risks: [ { "key" => "billing" } ])
    second = round(pr_number: 6, phase: "published", created_at: 1.hour.ago, finished_at: 50.minutes.ago)
    round(pr_number: 7, phase: "published", dry_run: true)
    round(pr_number: 8, phase: "published", created_at: 60.days.ago)
    first.check_runs.create!(review_rule: @check, check_key: "page-budgets", check_version: 1, status: "passed", run:)
    second.check_runs.create!(review_rule: @check, check_key: "page-budgets", check_version: 1, status: "reused")
    3.times { Harbor::ReviewFeedback.create!(review_round: first, subject_kind: "check", subject_key: "page-budgets", signal: "useful") }
    Harbor::ReviewFeedback.create!(review_round: first, subject_kind: "check", subject_key: "page-budgets", signal: "overridden")
    Harbor::ReviewFeedback.create!(review_round: first, subject_kind: "finding", subject_key: "caching", signal: "noise")
    Harbor::ReviewEscape.create!(repo: "acme/shop", pr_number: 5, source: "regressed_in", ref: "#9->#5", note: "Fixed by #9",
                                 analysis: "A check on rounding would have caught it.", review_round: first)

    get harbor.review_dashboard_path
    assert_response :success
    assert_select "title", text: "Review dashboard"
    tiles = css_select("section.grid div.meta").map { |label| [ label.text, label.next_element.text ] }.first(5)
    assert_equal [ [ "Rounds", "2" ], [ "PRs", "2" ], [ "Rounds per PR", "1.0" ], [ "Evidence", "$2.00" ], [ "Median to approval", "120 min" ] ], tiles
    assert_select "p", text: "1 check result reused instead of re-run."
    assert_equal [ "page-budgets", "2", "$2.00", "2", "0", "0", "75% (3/4)" ], css_select("tbody tr td").map(&:text)
    assert_select "div", text: "billing · $2.00"
    assert_select "div", text: "caching · useful 0, dismissed 1"
    assert_select "div", text: /#5 · Regressed in · Fixed by #9\s+· round 1/
    assert_select "p", text: "A check on rounding would have caught it."

    get harbor.review_dashboard_path(days: 90)
    assert_equal [ "Rounds", "3" ], css_select("section.grid div.meta").map { |label| [ label.text, label.next_element.text ] }.first
  end

  test "with the page switched off the rules, a round and the dashboard answer as not found" do
    open = round
    Harbor::Setting.set!(:page_reviews, false)
    [ harbor.reviews_path, harbor.new_review_rule_path, harbor.review_round_path(open), harbor.review_dashboard_path ].each do |path|
      get path
      assert_response :not_found, path
    end
    get "/"
    assert_select "[data-harbor-menu] a", text: "Review policy", count: 0
  end

  # --- what a host adds ---

  class HostVersion < Harbor::ReviewRuleVersion
    def author_label = created_by_user_id && "user #{created_by_user_id}"
  end

  class HostRule < Harbor::ReviewRule
    has_many :versions, -> { order(:number) }, class_name: "HarborReviewPagesTest::HostVersion", foreign_key: :review_rule_id, dependent: :destroy

    def self.page_defaults = { repo: "acme/shop" }

    def self.definition_template(kind) = kind == "signoff" ? super.merge("who" => [ "sam" ]) : super
  end

  test "a host's rule class says what a new rule starts with, and its versions say who saved them" do
    Harbor.config.review_rule_class = HostRule.name
    get harbor.new_review_rule_path(kind: "signoff")
    assert_select "input[name='review_rule[repo]'][value='acme/shop']"
    assert_equal [ "sam" ], JSON.parse(css_select("textarea[name=definition]").first.text)["who"]

    create_rule(RISK, repo: "acme/shop")
    made = HostRule.find_by!(key: "billing")
    made.versions.first.update_columns(created_by_user_id: 7)
    get harbor.review_rule_path(made)
    assert_select "span.text-faint", text: /· user 7\z/
  end

  test "pull requests are linked where the host says where they are" do
    Harbor.config.review_pull_request_url = ->(repo, number) { "https://git.example.com/#{repo == '*' ? 'acme/shop' : repo}/pulls/#{number}" }
    get harbor.review_round_path(round)
    assert_select "h1 a[href='https://git.example.com/acme/shop/pulls/5']", text: "PR #5"
  end

  test "a host's preview is offered for risks and sign-offs, started as its run and shown when it finishes" do
    policy
    asked = []
    Harbor.config.review_pull_request_url = ->(repo, number) { "https://git.example.com/#{repo == '*' ? 'acme/shop' : repo}/pulls/#{number}" }
    Harbor.config.review_rule_preview_sample = "the last 50 merged PRs"
    Harbor.config.review_rule_preview = lambda do |rule, definition, user:|
      asked << [ rule.key, definition, user&.name ]
      Harbor::Run.create!(skill: "reviews.rule-preview", status: "queued")
    end

    get harbor.new_review_rule_path(kind: "risk")
    assert_select "p", text: /Preview\s+shows which recent PRs/
    get harbor.review_rule_path(@check)
    assert_select "form[action=?]", harbor.preview_review_rule_path(@check), count: 0
    get harbor.review_rule_path(@risk)
    assert_select "form[action=?] button", harbor.preview_review_rule_path(@risk), text: "Preview on recent PRs"
    get harbor.edit_review_rule_path(@risk)
    assert_select "form[action=?] input[type=submit][value=?]", harbor.preview_review_rule_path(@risk), "Preview the saved version on the last 50 merged PRs"

    post harbor.preview_review_rule_path(@risk)
    run = Harbor::Run.last
    assert_redirected_to harbor.review_rule_path(@risk, preview_run: run.id)
    assert_equal [ [ "billing", @risk.definition, "Sam Settings" ] ], asked
    follow_redirect!
    assert_select "[data-controller='harbor--poll'][data-harbor--poll-interval-value='3']"
    assert_select "p", text: "Checking the last 50 merged PRs…"

    run.finish!(status: "ok", output: { "message" => "matched 1 of the last 50 merged PRs",
                                        "matches" => [ { "number" => 41, "title" => "Refund rounding", "reasons" => [ "app/billing/refund.rb" ] } ] })
    get harbor.review_rule_path(@risk, preview_run: run.id)
    assert_select "[data-controller='harbor--poll']", count: 0
    assert_select "p", text: "matched 1 of the last 50 merged PRs"
    assert_select "a[href='https://git.example.com/acme/shop/pulls/41']", text: "#41"
    assert_select "span.text-faint", text: "· app/billing/refund.rb"

    # As edited, not as saved; and JSON that doesn't parse goes back to the form.
    post harbor.preview_review_rule_path(@risk), params: { definition: RISK.merge("label" => "risk: money").to_json }
    assert_equal "risk: money", asked.last.second["label"]
    post harbor.preview_review_rule_path(@risk), params: { definition: "{nope" }
    assert_redirected_to harbor.edit_review_rule_path(@risk)

    # A check has nothing to try without running it.
    assert_no_difference("Harbor::Run.count") { post harbor.preview_review_rule_path(@check) }
    assert_redirected_to harbor.review_rule_path(@check)
  end

  test "with no preview a request for one starts nothing and says so" do
    policy
    assert_no_difference("Harbor::Run.count") { post harbor.preview_review_rule_path(@risk) }
    assert_redirected_to harbor.review_rule_path(@risk)
    follow_redirect!
    assert_select "[data-alert]", text: "This site has no preview for a risk."
  end

  test "the dashboard shows what the host says the reviews cost, and the finding categories it declared" do
    since = nil
    Harbor.config.review_cost = ->(time) { since = time; 12.5 }
    Harbor::Reviews.finding_category "caching"
    Harbor::Reviews.finding_category "general"
    open = round
    Harbor::ReviewFeedback.create!(review_round: open, subject_kind: "finding", subject_key: "caching", signal: "useful")
    Harbor::ReviewFeedback.create!(review_round: open, subject_kind: "finding", subject_key: "undeclared", signal: "useful")
    Harbor::ReviewFeedback.create!(review_round: open, subject_kind: "check", subject_key: "general", signal: "overridden")

    get harbor.review_dashboard_path(days: 7)
    tiles = css_select("section.grid div.meta").map { |label| [ label.text, label.next_element.text ] }.first(6)
    assert_equal [ "Rounds", "PRs", "Rounds per PR", "Evidence", "Code review", "Median to approval" ], tiles.map(&:first)
    assert_equal "$12.50", tiles[4].last
    assert_in_delta 7.days.ago.to_f, since.to_f, 60
    assert_select "section.grid.lg\\:grid-cols-6"
    assert_select "div", text: "caching · useful 1, dismissed 0"
    assert_select "div", text: "general · useful 0, dismissed 1"
    assert_select "div", text: /undeclared/, count: 0
  end

  test "a host's partial words the review, and the site's quality guide heads the policy page" do
    host_views
    recorded = round(phase: "published", review: { "verdict" => "APPROVE" })
    get harbor.review_round_path(recorded)
    assert_select "[data-host-review]", text: "Host review of round 1: APPROVE"
    assert_select "[data-review-verdict]", count: 0

    get harbor.reviews_path
    assert_select "[data-quality-guide=reviews]" do
      assert_select "li", count: 4
      assert_select "a[href=?]", harbor.review_dashboard_path, text: "dashboard"
    end
  end

  test "the document a round is read as carries the site's name for it" do
    Harbor.config.review_document_schema = "acme.review/v2"
    open = round
    get harbor.review_round_path(open)
    assert_select "summary", text: "Document (acme.review/v2)"
    get harbor.review_round_path(open, format: :json)
    assert_equal "acme.review/v2", JSON.parse(response.body)["schema"]
  end
end
