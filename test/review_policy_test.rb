require "test_helper"

# Review policy's records: a rule and its versions, what a rule may say, a
# round with its checks as one document, feedback and escapes, and what a
# host declares, names and is handed.
class HarborReviewPolicyTest < ActiveSupport::TestCase
  include HarborTestConfig

  CONFIG = %i[review_rule_class review_rule_version_class review_document_schema].freeze
  Definition = Harbor::Reviews::RuleDefinition
  Document = Harbor::Reviews::Document

  setup do
    Harbor::Reviews.reset!
    @review_config = CONFIG.index_with { |name| Harbor.config.public_send(name) }
    [ Harbor::ReviewFeedback, Harbor::ReviewEscape, Harbor::ReviewCheckRun, Harbor::ReviewRound,
      Harbor::ReviewRuleVersion, Harbor::ReviewRule, Harbor::Run ].each(&:delete_all)
  end

  teardown do
    Harbor::Reviews.reset!
    @review_config.each { |name, value| Harbor.config.public_send("#{name}=", value) }
  end

  def check_definition(**over)
    { "mitigates" => [ "perf" ], "kind" => "command", "run" => { "command" => "bin/x --json" },
      "outputs" => [ { "name" => "pages_over", "type" => "list" } ],
      "pass_when" => { "path" => "outputs.pages_over", "op" => "blank" } }.merge(over)
  end

  def check_rule(key = "page-budgets", **over)
    Harbor::ReviewRule.new(kind: "check", key:, name: key.tr("-", " ").capitalize).tap { |rule| rule.save_definition!(check_definition(**over)) }
  end

  def round(**attrs) = Harbor::ReviewRound.create!({ repo: "acme/shop", pr_number: 5, head_sha: "abcdef1234" }.merge(attrs))

  # --- a rule and its versions ---

  test "saving a definition makes a version only when it changed" do
    rule = Harbor::ReviewRule.new(kind: "check", key: "page-budgets", name: "Page budgets")
    first, errors = rule.save_definition!(check_definition)
    assert_empty errors
    assert_equal [ 1, 1, "*" ], [ first.number, rule.version_number, rule.repo ]
    same, = rule.save_definition!(check_definition)
    assert_equal first, same
    second, = rule.save_definition!(check_definition("gate" => "advisory"))
    assert_equal 2, second.number
    assert_equal "advisory", rule.reload.definition["gate"]
    assert_equal [ 1, 2 ], rule.versions.map(&:number)
  end

  test "a check's definition is filled in with its gate, stage and how it passes" do
    rule = Harbor::ReviewRule.new(kind: "check", key: "n1", name: "N+1")
    rule.save_definition!({ "mitigates" => [ "perf" ], "kind" => "ci", "run" => { "job" => "N+1 report" } })
    assert_equal [ "blocking", "evidence", "ci_success", [], [], [] ],
                 rule.definition.values_at("gate", "stage", "pass_when", "outputs", "then", "watch_paths")
  end

  test "a definition that can't be saved says why and saves nothing" do
    rule = Harbor::ReviewRule.new(kind: "check", key: "bad", name: "Bad")
    version, errors = rule.save_definition!(check_definition("kind" => "magic", "then" => [ { "action" => "explode" } ],
                                                             "pass_when" => { "path" => "", "op" => "roughly" }))
    assert_nil version
    assert_equal [ "kind must be one of ci, command, agent", "pass_when: a condition needs a path",
                   "pass_when: op must be one of #{Harbor::Reviews::Condition::OPS.join(', ')}",
                   "then[0]: action must be one of block, note, signoff, run, tell_reviewer" ], errors
    assert rule.new_record?
    assert_equal 0, Harbor::ReviewRuleVersion.count
  end

  test "rolling back saves the old definition as a new version" do
    rule = check_rule
    rule.save_definition!(check_definition("gate" => "advisory"))
    third, = rule.roll_back_to!(1)
    assert_equal 3, third.number
    assert_equal "blocking", rule.reload.definition["gate"]
  end

  test "a key is unique within its kind and repository, and is a slug" do
    check_rule
    again = Harbor::ReviewRule.new(kind: "check", key: "page-budgets", name: "Again")
    assert_not again.valid?
    assert Harbor::ReviewRule.new(kind: "risk", key: "page-budgets", name: "A risk").valid?
    assert Harbor::ReviewRule.new(kind: "check", key: "page-budgets", name: "Elsewhere", repo: "acme/other").valid?
    assert_not Harbor::ReviewRule.new(kind: "check", key: "Page Budgets", name: "Spaces").valid?
    assert_not Harbor::ReviewRule.new(kind: "hunch", key: "x", name: "X").valid?
    assert_not Harbor::ReviewRule.new(kind: "check", key: "x", name: "X", mode: "loud").valid?
  end

  test "rules are found by kind, by whether they run, and by repository" do
    check = check_rule
    risk = Harbor::ReviewRule.new(kind: "risk", key: "ui", name: "UI", repo: "acme/shop", mode: "off")
    risk.save_definition!({ "label" => "risk: ui", "detector" => { "paths" => [ "app/views/" ] } })
    assert_equal [ [ check ], [ risk ], [] ], [ Harbor::ReviewRule.checks.to_a, Harbor::ReviewRule.risks.to_a, Harbor::ReviewRule.signoffs.to_a ]
    assert_equal [ check ], Harbor::ReviewRule.running.to_a
    assert_equal [ check, risk ], Harbor::ReviewRule.for_repo("acme/shop").order(:id).to_a
    assert_equal [ check ], Harbor::ReviewRule.for_repo("acme/other").to_a
  end

  # --- what a rule may say ---

  test "a risk needs a label and a detector whose patterns are regular expressions" do
    assert_equal [ "a risk needs a label", "a risk needs a detector" ], Definition.errors("risk", {})
    assert_equal [ "a detector needs paths, patch or words" ], Definition.errors("risk", { "label" => "x", "detector" => {} })
    errors = Definition.errors("risk", { "label" => "x", "detector" => { "paths" => [ "app/(" ], "words" => "pay" } })
    assert_equal 1, errors.size
    assert_match(/\Abad pattern "app\/\("/, errors.first)
    assert_empty Definition.errors("risk", { "label" => "x", "detector" => { "patch" => [ "update_all" ] } })
  end

  test "a risk may name a detector only when the site declared it" do
    named = { "label" => "risk: migration", "detector" => { "builtin" => "risk: migration" } }
    assert_equal [ 'unknown builtin detector "risk: migration"' ], Definition.errors("risk", named)
    Harbor::Reviews.detector "risk: migration"
    Harbor::Reviews.detector "risk: migration"
    assert_equal [ "risk: migration" ], Harbor::Reviews.detectors
    assert_empty Definition.errors("risk", named)
  end

  test "a check says what it runs for its kind, names its outputs and routes with known actions" do
    assert_equal [ "a ci check needs run.job" ], Definition.errors("check", Definition.normalize("check", check_definition("kind" => "ci")))
    assert_equal [ "an agent check needs run.prompt" ], Definition.errors("check", Definition.normalize("check", check_definition("kind" => "agent")))
    assert_equal [ "a command check needs run.command" ], Definition.errors("check", Definition.normalize("check", check_definition("run" => {})))
    assert_equal [ "a check must mitigate at least one risk (or \"*\")" ], Definition.errors("check", Definition.normalize("check", check_definition("mitigates" => [])))
    assert_equal [ "an output needs a name", "output : type must be one of bool, number, string, list, object" ],
                 Definition.errors("check", Definition.normalize("check", check_definition("outputs" => [ {} ])))
    assert_equal [ "pass_when must be a condition or one of exit_zero, ci_success, agent_verdict" ],
                 Definition.errors("check", Definition.normalize("check", check_definition("pass_when" => "probably")))
    rows = [ { "action" => "signoff" }, { "action" => "run" }, { "action" => "note", "when" => { "any" => "x" } } ]
    assert_equal [ "then[0]: a signoff action names the signoff", "then[1]: a run action names the check", "then[2]: all/any takes a list",
                   "then[2]: a condition must be an object" ],
                 Definition.errors("check", Definition.normalize("check", check_definition("then" => rows)))
    assert_equal [ "gate must be blocking or advisory", "stage must be one of evidence, after_approval, after_deploy" ],
                 Definition.errors("check", Definition.normalize("check", check_definition("gate" => "soft", "stage" => "later")))
  end

  test "a sign-off needs someone and a message, and an unknown kind is refused" do
    assert_equal [ "a sign-off needs who", "a sign-off needs a message" ], Definition.errors("signoff", {})
    assert_empty Definition.errors("signoff", { "who" => [ "sam" ], "message" => "Approve it" })
    assert_equal [ 'unknown kind "hunch"' ], Definition.errors("hunch", {})
  end

  test "the definition a new rule starts with can be saved as it is, for every kind" do
    Harbor::ReviewRule::KINDS.each do |kind|
      template = Harbor::ReviewRule.definition_template(kind)
      assert_empty Definition.errors(kind, Definition.normalize(kind, template)), kind
    end
  end

  test "a condition is put in words" do
    describe = Harbor::Reviews::Condition.method(:describe)
    assert_equal "always", describe.call(nil)
    assert_equal "outputs.pages_over blank", describe.call({ "path" => "outputs.pages_over", "op" => "blank" })
    assert_equal "outputs.ok eq true and (outputs.n gt 5 or not outputs.kind not in a, b)",
                 describe.call({ "all" => [ { "path" => "outputs.ok", "op" => "eq", "value" => true },
                                            { "any" => [ { "path" => "outputs.n", "op" => "gt", "value" => 5 },
                                                         { "not" => { "path" => "outputs.kind", "op" => "not_in", "values" => %w[a b] } } ] } ] })
    assert_equal [ "a condition must be an object" ], Harbor::Reviews::Condition.validate("x")
  end

  test "path globs match the way people write them" do
    glob = Harbor::Reviews::Glob
    assert glob.match?("**/db/migrate/**", "db/migrate/1_add.rb")
    assert glob.match?("**/db/migrate/**", "api/db/migrate/1_add.rb")
    assert glob.match?("app/*.rb", "app/shop.rb")
    assert_not glob.match?("app/*.rb", "app/models/shop.rb")
    assert glob.match?("app/**", "app/models/shop.rb")
    assert glob.match?("**/*.{css,scss}", "app/assets/site.scss")
    assert_not glob.match?("**/*.{css,scss}", "app/assets/site.js")
    assert glob.match?("file?.txt", "file1.txt")
    assert_not glob.match?("file?.txt", "file/.txt")
    assert glob.match?("a{b", "a{b")
  end

  # --- a round and its checks ---

  test "a round has one unfinished round per pull request, a join key and the rounds before it" do
    first = round(phase: "published", round: 1)
    second = round(head_sha: "bbbbbbb", round: 2)
    assert_raises(ActiveRecord::RecordNotUnique) { round(head_sha: "ccccccc", round: 3) }
    assert_equal [ first ], second.previous_rounds.to_a
    assert_equal [ second ], Harbor::ReviewRound.open_rounds.to_a
    assert_equal "review:acme/shop#5@bbbbbbb", second.join_key
    assert_equal [ first, second ], Harbor::ReviewRound.for_pr("acme/shop", "5").order(:id).to_a
    assert_not Harbor::ReviewRound.new(repo: "acme/shop", pr_number: 5, head_sha: "x", phase: "limbo").valid?
  end

  test "cancelling a round cancels the checks still under way and leaves the finished ones" do
    rule = check_rule
    other = check_rule("repro-test")
    open = round
    passed = open.check_runs.create!(review_rule: rule, check_key: rule.key, check_version: 1, status: "passed")
    running = open.check_runs.create!(review_rule: other, check_key: other.key, check_version: 1, status: "running")
    open.cancel!(reason: "a newer commit", superseded_by: "fffffff")
    assert_equal [ "cancelled", "a newer commit", "fffffff" ], [ open.phase, open.error, open.superseded_by_sha ]
    assert_equal [ "passed", "cancelled" ], [ passed.reload.status, running.reload.status ]
    assert open.finished?
    assert_nil open.cancel!(reason: "again")
  end

  test "a check run reads the version it ran, and a reused one counts as what it reused" do
    rule = check_rule
    rule.save_definition!(check_definition("gate" => "advisory"))
    earlier = round(phase: "published").check_runs.create!(review_rule: rule, check_key: rule.key, check_version: 1, status: "failed")
    reused = round(head_sha: "bbbbbbb", round: 2).check_runs.create!(review_rule: rule, check_key: rule.key, check_version: 1,
                                                                     status: "reused", reused_from: earlier, mode: "shadow")
    assert_equal "blocking", reused.definition["gate"]
    assert_equal [ "failed", true, true, true ], [ reused.effective_status, reused.done?, reused.shadow?, reused.blocking? ]
    reused.update!(check_version: 9)
    assert_equal "advisory", reused.definition["gate"]
    earlier.finish!(status: "passed", summary: "fine", outputs: { "pages_over" => [] })
    assert_equal [ "passed", "fine", { "pages_over" => [] } ], [ earlier.status, earlier.summary, earlier.outputs ]
    assert earlier.finished_at
  end

  test "a round reads as one document: its checks, progress, cost and where it is" do
    rule = check_rule
    slow = check_rule("repro-test")
    shadow = check_rule("decisions")
    run = Harbor::Run.create!(skill: "reviews.check", status: "ok", cost_usd_actual: 1.25)
    review_run = Harbor::Run.create!(skill: "reviews.code", status: "ok", cost_usd_estimate: 0.5)
    open = round(phase: "evidence", risks: [ { "key" => "perf", "reasons" => [ "app/models/shop.rb" ] } ],
                 input: { "code_review_run_id" => review_run.id, "workspace_path" => "/work/5" })
    open.check_runs.create!(review_rule: rule, check_key: rule.key, check_version: 1, status: "passed", run:, summary: "0 pages over")
    open.check_runs.create!(review_rule: slow, check_key: slow.key, check_version: 1, status: "running", progress_done: 1, progress_total: 4)
    open.check_runs.create!(review_rule: shadow, check_key: shadow.key, check_version: 1, status: "failed", mode: "shadow")

    doc = Document.for(open)
    assert_equal [ "harbor.review/v1", open.id, "acme/shop", 5, "evidence" ], doc.values_at("schema", "round_id", "repo", "pr", "phase")
    assert_equal({ "percent" => 48, "done" => 1, "total" => 2 }, doc["progress"])
    assert_equal %w[page-budgets repro-test decisions], doc["checks"].map { |c| c["key"] }
    assert_equal [ "Page budgets", 1, "passed", "0 pages over", run.id, "command" ],
                 doc["checks"].first.values_at("name", "version", "status", "summary", "run_id", "kind")
    assert_equal({ "done" => 1, "total" => 4, "note" => nil }, doc["checks"].second["progress"])
    assert_equal({ "result" => "pending", "blocking_failures" => [] }, doc["gate"])
    assert_equal({ "status" => "pending" }, doc["review"])
    assert_equal({ "code_review_run_id" => review_run.id }, doc["input"])
    assert_match(/\A\$1\.75 · 0 min · 3 checks\z/, doc["cost"])
    assert_equal "Evidence 1 of 2 · 48%", Document.title(doc)
  end

  test "a round's title says how it came out" do
    title = ->(**doc) { Document.title({ "progress" => { "total" => 0 }, "checks" => [ { "key" => "pb", "name" => "Page budgets" } ] }.merge(doc.stringify_keys)) }
    assert_equal "Planning evidence", title.(phase: "triage")
    assert_equal "No evidence needed", title.(phase: "evidence")
    assert_equal "Evidence 1 of 2 · 40% · about 2 min left", title.(phase: "evidence", progress: { "total" => 2, "done" => 1, "percent" => 40, "eta_seconds" => 100 })
    assert_equal "Evidence passed · reviewing the code", title.(phase: "review")
    assert_equal "Superseded by fffffff", title.(phase: "cancelled", input: { "superseded_by" => "fffffff" })
    assert_equal "Evidence failed: Page budgets, other", title.(phase: "published", gate: { "result" => "failed", "blocking_failures" => %w[pb other] })
    assert_equal "Changes requested: 1 blocking", title.(phase: "published", review: { "verdict" => "REQUEST_CHANGES", "findings" => [ { "severity" => "blocking" }, { "severity" => "nit" } ] })
    assert_equal "Waiting on sam: New table", title.(phase: "signoffs", review: { "verdict" => "APPROVE" },
                                                     signoffs: [ { "status" => "waiting", "who" => [ "sam" ], "name" => "New table" },
                                                                 { "status" => "waiting", "who" => [ "kit" ], "name" => "Quiet", "mode" => "shadow" } ])
    assert_equal "Approved", title.(phase: "published", review: { "verdict" => "APPROVE" })
    assert_equal "Needs a person", title.(phase: "published", review: { "verdict" => "COMMENT" })
  end

  test "the document carries the name the site gives its format" do
    Harbor.config.review_document_schema = "acme.review/v2"
    assert_equal "acme.review/v2", Document.for(round)["schema"]
  end

  # --- afterwards ---

  test "feedback rolls up into precision per subject" do
    open = round
    signal = ->(kind, key, value) { Harbor::ReviewFeedback.create!(review_round: open, subject_kind: kind, subject_key: key, signal: value) }
    3.times { signal.("check", "page-budgets", "useful") }
    signal.("check", "page-budgets", "overridden")
    signal.("check", "repro-test", "accepted")
    signal.("finding", "caching", "noise")
    assert_equal({ "page-budgets" => { useful: 3, noise: 1, precision: 75 }, "repro-test" => { useful: 0, noise: 0, precision: nil } },
                 Harbor::ReviewFeedback.precision_by("check"))
    assert_equal({ "caching" => { useful: 0, noise: 1, precision: 0 } }, Harbor::ReviewFeedback.precision_by("finding"))
    assert_not Harbor::ReviewFeedback.new(review_round: open, subject_kind: "check", subject_key: "x", signal: "meh").valid?
  end

  test "an escape names where it was noticed and may point at the round that approved it" do
    escape = Harbor::ReviewEscape.create!(repo: "acme/shop", pr_number: 5, source: "regressed_in", ref: "#9->#5", review_round: round)
    assert_equal 5, escape.review_round.pr_number
    assert Harbor::ReviewEscape.new(repo: "acme/shop", pr_number: 6, source: "deploy_errors").valid?
    assert_not Harbor::ReviewEscape.new(repo: "acme/shop", pr_number: 6, source: "a hunch").valid?
  end

  # --- what a host is handed, and names ---

  test "every saved version is handed to the host to keep, and a hook that fails loses nothing" do
    kept = {}
    Harbor.config.export = ->(path, body) { kept[path] = JSON.parse(body) }
    rule = Harbor::ReviewRule.new(kind: "check", key: "page-budgets", name: "Page budgets", repo: "acme/shop", mode: "shadow")
    rule.save_definition!(check_definition)
    assert_equal [ "reviews/checks/acme_shop/page-budgets.json" ], kept.keys
    assert_equal [ "check", "page-budgets", "acme/shop", "Page budgets", "shadow", 1, rule.definition ],
                 kept.values.first.values_at("kind", "key", "repo", "name", "mode", "version", "definition")

    everywhere = Harbor::ReviewRule.new(kind: "signoff", key: "api", name: "API")
    everywhere.save_definition!({ "who" => [ "sam" ], "message" => "Approve it" })
    assert_includes kept.keys, "reviews/signoffs/_all/api.json"

    Harbor.config.export = ->(*) { raise "disk full" }
    version, errors = rule.save_definition!(check_definition("gate" => "advisory"))
    assert_equal [ 2, [] ], [ version.number, errors ]
  end

  # A host's classes: the repository it reviews, and versions that know who
  # saved them.
  class HostVersion < Harbor::ReviewRuleVersion
    def author_label = created_by_user_id && "user #{created_by_user_id}"
  end

  class HostRule < Harbor::ReviewRule
    def self.page_defaults = { repo: "acme/shop" }
  end

  test "a host's subclasses are what Harbor builds and finds" do
    Harbor.config.review_rule_class = HostRule.name
    Harbor.config.review_rule_version_class = HostVersion.name
    rule = HostRule.new(kind: "check", key: "page-budgets", name: "Page budgets")
    version, = rule.save_definition!(check_definition, user: Struct.new(:id).new(7))
    assert_equal [ HostRule, HostVersion ], [ Harbor.review_rule_class, Harbor.review_rule_version_class ]
    assert_equal [ 7, "user 7" ], [ version.created_by_user_id, HostVersion.find(version.id).author_label ]
    assert_nil Harbor::ReviewRuleVersion.find(version.id).author_label
    assert_equal({ repo: "acme/shop" }, Harbor.review_rule_class.page_defaults)
    assert_equal({}, Harbor::ReviewRule.page_defaults)
  end
end
