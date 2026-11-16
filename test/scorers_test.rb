require "test_helper"

# Scorers and their verdicts: the records, which runs they judge, the claim
# that keeps one judge per scorer and run, the prompt and reading a verdict.
class HarborScorersTest < ActiveSupport::TestCase
  include HarborQuality

  class HostScorer < Harbor::Scorer
    def self.task_types = super + %w[automation]
    def self.draft = super.tap { |scorer| scorer.sample_rate = 10 }
  end

  def build(**attributes)
    Harbor::Scorer.new({ name: "Tests ran #{SecureRandom.hex(3)}", judge_instructions: "Did it run the tests?", model_alias: @alias,
                         classifications: [ { "label" => "pass", "score" => 1.0 }, { "label" => "fail", "score" => 0.0 } ] }.merge(attributes))
  end

  test "a scorer needs a name of its own, instructions, a model alias and sound numbers" do
    assert build.valid?
    assert_not build(name: "").valid?
    assert_not build(judge_instructions: "").valid?
    assert_not build(model_alias: nil).valid?
    assert_not build(sample_rate: 101).valid?
    assert_not build(pass_threshold: 1.5).valid?
    assert_not build(improvement_min_failures: 0).valid?
    assert_not build(improvement_max_age_days: 91).valid?
    taken = build.tap(&:save!)
    assert_not build(name: taken.name).valid?
  end

  test "classifications need unique labels with scores between 0 and 1" do
    assert_not build(classifications: []).valid?
    assert_not build(classifications: [ { "label" => "pass", "score" => 2 } ]).valid?
    assert_not build(classifications: [ { "label" => "pass", "score" => 1 }, { "label" => "Pass", "score" => 0 } ]).valid?
    assert_not build(classifications: [ { "score" => 1 } ]).valid?
  end

  test "applies_to? narrows by agent and task type, empty meaning any" do
    run = Harbor::Run.new(agent_key: "writer", task_type: "review")
    assert build.applies_to?(run)
    assert build(agent_keys: [ "writer" ]).applies_to?(run)
    assert_not build(agent_keys: [ "editor" ]).applies_to?(run)
    assert build(task_types: [ "review" ]).applies_to?(run)
    assert_not build(task_types: [ "rebase" ]).applies_to?(run)
  end

  test "applicable_to lists the enabled scorers that apply, in order" do
    second = new_scorer(name: "B", position: 1)
    first = new_scorer(name: "A", position: 0)
    new_scorer(name: "Off", enabled: false)
    new_scorer(name: "Other", task_types: [ "rebase" ])
    assert_equal [ first, second ], Harbor::Scorer.applicable_to(agent_run)
  end

  test "sampled? follows the rate and score_for maps a label however it is cased" do
    assert_not build(sample_rate: 0).sampled?
    assert build(sample_rate: 100).sampled?
    assert build(sample_rate: 50).sampled?(rng: Struct.new(:v) { def rand(_) = v }.new(10))
    assert_not build(sample_rate: 50).sampled?(rng: Struct.new(:v) { def rand(_) = v }.new(60))
    assert_equal 1.0, build.score_for("PASS")
    assert_nil build.score_for("meh")
  end

  test "parse_classifications reads label=score lines and rejects nonsense" do
    assert_equal [ { "label" => "pass", "score" => 1.0 }, { "label" => "partial", "score" => 0.5 } ],
                 Harbor::Scorer.parse_classifications("pass=1\n\npartial = 0.5\n")
    assert_raises(ArgumentError) { Harbor::Scorer.parse_classifications("") }
    assert_raises(ArgumentError) { Harbor::Scorer.parse_classifications("pass") }
    error = assert_raises(ArgumentError) { Harbor::Scorer.parse_classifications("pass=high") }
    assert_equal "Scores must be numbers between 0 and 1.", error.message
    assert_equal "pass=1.0\nfail=0.0", build.classifications_text
  end

  test "pass rate and the weekly series count judged runs only" do
    # A fixed midweek moment: in the first hours of a Monday the results
    # below would be dated later than now, and the test failed then.
    travel_to Time.utc(2026, 11, 11, 12)
    scorer = new_scorer
    week = Time.current.beginning_of_week
    Harbor::ScorerResult.create!(scorer:, run: agent_run, status: "ok", passed: true, classification: "pass", score: 1, scored_at: week + 1.hour)
    Harbor::ScorerResult.create!(scorer:, run: agent_run, status: "ok", passed: false, classification: "fail", score: 0, scored_at: week + 2.hours)
    Harbor::ScorerResult.create!(scorer:, run: agent_run, status: "error", error: "no verdict")
    assert_equal 50, scorer.pass_rate(since: 8.days.ago)
    assert_nil scorer.pass_rate(since: 1.minute.from_now)
    series = scorer.weekly_pass_series(since: 2.weeks.ago)
    assert_equal 3, series.size
    assert_equal [ 0, 0, 50 ], series.map(&:last)
  end

  test "the task types offered are the declared ones, and a new scorer starts by hand" do
    Harbor::TaskTypes.reset!
    Harbor::TaskTypes.declare "review"
    assert_equal %w[review], Harbor::Scorer.task_types
    draft = Harbor::Scorer.draft
    assert_equal [ 0, 1.0, %w[pass fail] ], [ draft.sample_rate, draft.pass_threshold.to_f, draft.labels ]
    assert_nil draft.model_alias
  ensure
    Harbor::TaskTypes.reset!
  end

  test "a host's scorer class is the one Harbor builds, with its task types and starting values" do
    Harbor.config.scorer_class = HostScorer.name
    Harbor::TaskTypes.reset!
    assert_equal HostScorer, Harbor.scorer_class
    assert_equal %w[automation], Harbor.scorer_class.task_types
    assert_equal 10, Harbor.scorer_class.draft.sample_rate
  ensure
    Harbor::TaskTypes.reset!
  end

  test "a model alias a scorer judges with can't be deleted, and a deleted scorer takes its verdicts" do
    @agent.update!(model_alias: nil)
    scorer = new_scorer
    failure(scorer)
    assert_not @alias.destroy
    assert_match(/scorers/i, @alias.errors.full_messages.to_sentence)
    assert_difference("Harbor::ScorerResult.count", -1) { scorer.destroy }
    assert @alias.destroy, "with its scorer gone the alias goes, without being read again first"
  end

  # --- runs ---

  test "a finished top-level agent run with a transcript can be scored, and nothing else" do
    assert agent_run.scorable?
    assert agent_run(status: "error").scorable?
    assert agent_run(status: "timeout").scorable?
    assert_not agent_run(status: "running").scorable?
    assert_not agent_run(status: "skipped").scorable?
    assert_not agent_run(raw_log_path: nil).scorable?
    assert_not agent_run(agent_key: nil).scorable?
    assert_not agent_run(parent_run_id: agent_run.id).scorable?
    assert_not agent_run(skill: "scorer").scorable?, "a judge is never judged"
  end

  test "a finishing scorable run is handed to the sampler when there is a judge and an enabled scorer" do
    Harbor.config.scorer_judge = ->(_judgement) { "" }
    run = agent_run(status: "running")
    assert_no_enqueued_jobs(only: Harbor::Scorers::SampleJob) { run.finish!(status: "ok") }

    new_scorer(enabled: false)
    assert_no_enqueued_jobs(only: Harbor::Scorers::SampleJob) { agent_run(status: "running").finish!(status: "ok") }

    new_scorer
    run = agent_run(status: "running")
    assert_enqueued_with(job: Harbor::Scorers::SampleJob, args: [ run.id ]) { run.finish!(status: "ok") }
    assert_no_enqueued_jobs(only: Harbor::Scorers::SampleJob) { run.update!(error: "noted") }
    assert_no_enqueued_jobs(only: Harbor::Scorers::SampleJob) { agent_run(status: "running").finish!(status: "skipped") }
    assert_no_enqueued_jobs(only: Harbor::Scorers::SampleJob) { agent_run(status: "running", raw_log_path: nil).finish!(status: "ok") }
  end

  test "with no judge configured no run is sampled" do
    new_scorer(sample_rate: 100)
    assert_nil Harbor.config.scorer_judge
    assert_no_enqueued_jobs { agent_run(status: "running").finish!(status: "ok") }
  end

  test "a judge is a child run with a bill of its own, not part of the run's delegated work" do
    run = agent_run(cost_usd_actual: 2.0)
    delegated = Harbor::Run.create!(parent_run_id: run.id, agent_key: "editor", skill: "editor", status: "ok", cost_usd_estimate: 0.5)
    judge = Harbor::Run.create!(parent_run_id: run.id, skill: "scorer", status: "ok", cost_usd_actual: 0.1)
    run.reload
    assert_equal [ delegated ], run.delegated_runs
    assert_equal [ judge ], run.judge_runs
    assert_equal 1.5, run.own_cost_usd
  end

  test "a run awaits a verdict while a claim on it is pending and fresh" do
    scorer = new_scorer
    run = agent_run
    assert_not run.awaiting_verdict?
    row = Harbor::ScorerResult.claim!(scorer:, run:)
    assert run.reload.awaiting_verdict?
    row.update_columns(updated_at: 1.hour.ago)
    assert_not run.reload.awaiting_verdict?, "a judge that never answered isn't waited for"
    row.update!(status: "ok", passed: true)
    assert_not run.reload.awaiting_verdict?
  end

  test "deleting a run takes its verdicts with it" do
    scorer = new_scorer
    result = failure(scorer)
    assert_difference("Harbor::ScorerResult.count", -1) { result.run.destroy }
  end

  # --- the claim ---

  test "one judge per scorer and run: a second claim gets nothing until the verdict is in or the claim is stale" do
    scorer = new_scorer
    run = agent_run
    row = Harbor::ScorerResult.claim!(scorer:, run:)
    assert row.queued?
    assert_nil Harbor::ScorerResult.claim!(scorer:, run:)

    row.update!(status: "ok", passed: false, classification: "fail", score: 0, reasoning: "old reasoning", scored_at: Time.current)
    again = Harbor::ScorerResult.claim!(scorer:, run:)
    assert_equal row, again
    assert_equal [ "queued", nil, nil, nil, nil, nil ],
                 [ again.status, again.classification, again.score, again.passed, again.reasoning, again.scored_at ],
                 "a re-score starts from nothing"

    assert_nil Harbor::ScorerResult.claim!(scorer:, run:)
    row.update_columns(updated_at: 12.minutes.ago)
    assert Harbor::ScorerResult.claim!(scorer:, run:), "a claim older than the judge can take is given up"
  end

  test "how long a claim holds is the host's to say, as a duration or a callable" do
    assert_equal 11.minutes, Harbor::ScorerResult.stale_claim_after
    Harbor.config.scorer_judge_wait = 3.minutes
    assert_equal 3.minutes, Harbor::ScorerResult.stale_claim_after
    Harbor.config.scorer_judge_wait = -> { 90.seconds }
    assert_equal 90.seconds, Harbor::ScorerResult.stale_claim_after
  end

  test "failures are claimed for review once, and again only when the claim is stale" do
    scorer = new_scorer
    ids = 3.times.map { failure(scorer).id }
    assert_equal ids.sort, Harbor::ScorerResult.claim_for_review!(ids).sort
    assert_equal [], Harbor::ScorerResult.claim_for_review!(ids)
    assert_empty Harbor::ScorerResult.failed.unreviewed

    Harbor::ScorerResult.where(id: ids.first).update_all(claimed_at: 3.hours.ago)
    assert_equal [ ids.first ], Harbor::ScorerResult.claim_for_review!(ids)
    Harbor::ScorerResult.where(id: ids.last).update_all(reviewed_at: Time.current, claimed_at: nil)
    assert_equal [], Harbor::ScorerResult.claim_for_review!([ ids.last ]), "a reviewed row is never claimed"
    assert_equal [], Harbor::ScorerResult.claim_for_review!([])
  end

  # --- the prompt and the verdict ---

  test "the prompt names the run, the transcript, the question and the labels, and the site when it has a name" do
    scorer = new_scorer
    run = agent_run(command: "claude -p /review 41", output: { "text" => "Opened PR #42" }, cost_usd_actual: 1.5, duration_ms: 61_000)
    prompt = Harbor::Scorers::Prompt.build(scorer, run, transcript: "t.ndjson")
    assert_includes prompt, "You are a judge grading one finished agent run. Read the run's transcript"
    assert_includes prompt, "- Run ##{run.id}: writer.review"
    assert_includes prompt, "- Agent: writer · task type: review · skill: writer.review"
    assert_includes prompt, "- Command: claude -p /review 41"
    assert_includes prompt, "- Cost: $1.5000 · tokens: unknown · duration: 61s"
    assert_includes prompt, "`t.ndjson` in the current directory"
    assert_includes prompt, "Opened PR #42"
    assert_includes prompt, "Did it run the tests?"
    assert_includes prompt, "- pass (score 1.0)\n- partial (score 0.5)\n- fail (score 0.0)"
    assert_includes prompt, '{"classification": "<one of the labels above>"'
    assert_not_includes prompt, run.raw_log_path, "the judge is told the name it will find, not where Harbor keeps the file"

    Harbor.config.site_name = "Acme Factory"
    assert_includes Harbor::Scorers::Prompt.build(scorer, run), "one finished agent run for Acme Factory. Read"
  end

  test "a verdict is the last block naming one of the scorer's labels, fenced or bare" do
    labels = %w[pass partial fail]
    verdict = Harbor::Scorers::Verdict.parse("First ```json\n{\"classification\":\"fail\"}\n``` then\n```json\n{\"classification\":\"Partial\",\"score\":0.5,\"reasoning\":\" Ran early. \"}\n```", labels:)
    assert_equal [ "partial", "Ran early.", 0.5 ], [ verdict.classification, verdict.reasoning, verdict.judge_score ]
    assert_equal "pass", Harbor::Scorers::Verdict.parse('I think {"classification": "pass"} fits.', labels:).classification
    assert_nil Harbor::Scorers::Verdict.parse("```json\n{\"classification\":\"excellent\"}\n```", labels:)
    assert_nil Harbor::Scorers::Verdict.parse("I could not tell.", labels:)
    assert_nil Harbor::Scorers::Verdict.parse(nil, labels:)
  end
end
