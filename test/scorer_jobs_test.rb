require "test_helper"

# Judging a run: the judge run and the result Harbor makes, what it asks of
# the host's judge, and how each way a judge can end is recorded. And the
# sampler that queues judges for finished runs.
class HarborScorerJobsTest < ActiveSupport::TestCase
  include HarborQuality

  VERDICT = "Read it.\n```json\n{\"classification\":\"partial\",\"score\":0.5,\"reasoning\":\"Tests ran before the last edit.\"}\n```".freeze

  setup do
    @scorer = new_scorer
    @run = agent_run(output: { "text" => "Opened PR #42" })
  end

  # Stands in for a host's judge: answers with `text`, or does what the block says.
  def judge_with(text = nil, &block)
    seen = []
    Harbor.config.scorer_judge = lambda do |judgement|
      seen << judgement
      block ? block.call(judgement) : text
    end
    seen
  end

  def evaluate(**options)
    Harbor::Scorers::EvaluateJob.perform_now(scorer_id: @scorer.id, run_id: @run.id, trigger_source: "manual", **options)
  end

  def result = Harbor::ScorerResult.find_by!(scorer: @scorer, run: @run)

  test "the judge's answer is recorded on a child judge run and a result row" do
    seen = judge_with(VERDICT)
    evaluate(triggered_by_user_id: 7)

    assert_equal [ "ok", "partial", 0.5, false, "Tests ran before the last edit." ],
                 [ result.status, result.classification, result.score.to_f, result.passed, result.reasoning ]
    assert_not_nil result.scored_at
    judge = result.judge_run
    assert_equal [ @run.id, "scorer", "scorer:#{@scorer.id}", "manual", 7, "ok", "Harbor::Run", @run.id ],
                 [ judge.parent_run_id, judge.skill, judge.trigger, judge.trigger_source, judge.triggered_by_user_id, judge.status,
                   judge.subject_type, judge.subject_id ]
    assert_equal({ "scorer_id" => @scorer.id, "scorer" => @scorer.name, "run_id" => @run.id }, judge.input)
    assert_equal [ "partial", 0.5, false ], judge.output.values_at("classification", "score", "passed")
    assert_includes judge.output["text"], "Read it."
    assert_not_nil judge.ended_at

    judgement = seen.sole
    assert_equal [ @scorer, @run, judge, result, 0 ], [ judgement.scorer, judgement.run, judgement.judge, judgement.result, judgement.attempt ]
    assert_includes judgement.prompt, "Did it run the tests?"
    assert_includes judgement.prompt, "Opened PR #42"
    assert_includes judgement.prompt(transcript: "t.ndjson"), "`t.ndjson` in the current directory"
    assert_equal Harbor::LiveLog.absolute("writer/run.ndjson").to_s, judgement.transcript_file.to_s
    assert_includes Harbor::LiveLog.read(judge.live_log_path), "[scorer] partial (0.5) — fail"
  end

  test "a label at the threshold passes" do
    judge_with("```json\n{\"classification\":\"PASS\"}\n```")
    evaluate
    assert_equal [ "pass", 1.0, true ], [ result.classification, result.score.to_f, result.passed ]
  end

  test "a judge can answer for itself, with what it wants kept, and write the judge run's log" do
    judge_with do |judgement|
      judgement.judge.update!(model: "claude-haiku-5-5", command: "judge --model claude-haiku-5-5")
      judgement.log("[judge] reading the transcript")
      judgement.answer!(VERDICT, output: { exit_code: 0 })
    end
    evaluate
    judge = result.judge_run
    assert_equal [ "ok", "claude-haiku-5-5", 0, "partial" ], [ judge.status, judge.model, judge.output["exit_code"], judge.output["classification"] ]
    log = Harbor::LiveLog.read(judge.live_log_path)
    assert_operator log.index("[judge] reading the transcript"), :<, log.index("[scorer] partial")
  end

  test "with no judge configured the judgement is an error that says what the site has to do" do
    assert_nil Harbor.config.scorer_judge
    evaluate
    assert_equal [ "error", "error" ], [ result.status, result.judge_run.status ]
    assert_match "No judge is configured", result.error
    assert_match "Harbor.config.scorer_judge", result.judge_run.error
    assert_nil result.scored_at
  end

  test "no usable verdict is an error that keeps what the judge said" do
    judge_with("I could not tell.")
    evaluate
    assert_equal [ "error", "error" ], [ result.status, result.judge_run.status ]
    assert_equal "the judge gave no verdict matching pass/partial/fail", result.error
    assert_equal "I could not tell.", result.judge_run.output["text"]
  end

  test "a judge says why it couldn't run, and how the judge run ends" do
    judge_with { |judgement| judgement.fail!("the judge's machine is switched off", status: "skipped", output: { exit_code: 3 }) }
    evaluate
    assert_equal [ "error", "the judge's machine is switched off" ], [ result.status, result.error ]
    assert_equal [ "skipped", 3 ], [ result.judge_run.status, result.judge_run.output["exit_code"] ]

    judge_with { |judgement| judgement.fail!("stopped", status: "canceled") && "ignored" }
    evaluate
    assert_equal "canceled", result.reload.judge_run.status
  end

  test "a judge that raises is an error on both, not a job that dies" do
    judge_with { |_| raise IOError, "the pipe closed" }
    assert_nothing_raised { evaluate }
    assert_equal [ "error", "IOError: the pipe closed" ], [ result.status, result.error ]
    assert_equal "error", result.judge_run.status
  end

  test "no model to judge with is a skipped judge run" do
    @provider.update!(enabled: false)
    judge_with { |judgement| judgement.scorer.model_alias.resolve }
    evaluate
    assert_equal "error", result.status
    assert_match "No available model for Quick", result.error
    assert_equal "skipped", result.judge_run.status
  end

  test "a busy judge is tried again later with the claim still queued, a bounded number of times" do
    seen = judge_with { |_| raise Harbor::Scorers::Judgement::Busy, "one at a time — try again later" }
    assert_enqueued_with(job: Harbor::Scorers::EvaluateJob,
                         args: [ { scorer_id: @scorer.id, run_id: @run.id, trigger_source: "manual", triggered_by_user_id: nil, busy_retries: 1 } ]) do
      evaluate
    end
    assert_equal "queued", result.status
    assert_nil result.judge_run
    attempted = @run.child_runs.sole
    assert_equal "skipped", attempted.status
    assert_equal "judge busy — retrying in 2 minutes (1/10)", attempted.error

    evaluate(busy_retries: 4)
    assert_equal 4, seen.last.attempt

    assert_no_enqueued_jobs { evaluate(busy_retries: Harbor::Scorers::EvaluateJob::BUSY_RETRIES) }
    assert_equal "error", result.reload.status, "retries are bounded"
    assert_equal "the judge stayed busy through 10 retries: one at a time — try again later", result.error
  end

  test "a judge that answers later leaves the verdict pending until it does" do
    judge_with { |_| nil }
    evaluate
    judge = result.judge_run
    assert_equal [ "queued", "queued" ], [ result.status, judge.status ]
    assert @run.reload.awaiting_verdict?

    judgement = Harbor::Scorers::Judgement.for(judge)
    assert_equal [ @scorer, @run, result ], [ judgement.scorer, judgement.run, judgement.result ]
    judgement.answer!(VERDICT)
    judgement.close_log
    assert_equal [ "ok", "partial" ], [ result.reload.status, result.classification ]
    assert_equal "ok", judge.reload.status
    assert_not @run.reload.awaiting_verdict?
  end

  test "a judge run whose verdict was claimed again has no judgement to answer" do
    judge_with { |_| nil }
    evaluate
    judge = result.judge_run
    result.update!(judge_run: nil)
    assert_nil Harbor::Scorers::Judgement.for(judge)
  end

  test "re-scoring replaces the verdict instead of adding a row, and it is unreviewed again" do
    judge_with("```json\n{\"classification\":\"fail\"}\n```")
    evaluate
    result.update!(reviewed_at: 1.day.ago, claimed_at: 1.hour.ago)
    judge_with("```json\n{\"classification\":\"pass\"}\n```")
    evaluate
    assert_equal 1, Harbor::ScorerResult.where(scorer: @scorer, run: @run).count
    assert result.reload.passed
    assert_nil result.reviewed_at
    assert_nil result.claimed_at
    assert_equal 2, @run.child_runs.count, "each judgement is its own run"
  end

  test "a scorer or run that has gone is nothing to judge" do
    seen = judge_with(VERDICT)
    assert_no_difference("Harbor::Run.count") do
      Harbor::Scorers::EvaluateJob.perform_now(scorer_id: 0, run_id: @run.id)
      Harbor::Scorers::EvaluateJob.perform_now(scorer_id: @scorer.id, run_id: 0)
    end
    assert_empty seen
  end

  # --- the sampler ---

  test "a finished run is offered to the scorers that apply, at their rate" do
    always = new_scorer(sample_rate: 100)
    new_scorer(sample_rate: 0)
    new_scorer(sample_rate: 100, task_types: [ "rebase" ])
    new_scorer(sample_rate: 100, enabled: false)
    assert_enqueued_with(job: Harbor::Scorers::EvaluateJob, args: [ { scorer_id: always.id, run_id: @run.id, trigger_source: "watcher" } ]) do
      Harbor::Scorers::SampleJob.perform_now(@run.id)
    end
    assert_equal 1, enqueued_jobs.count { |job| job["job_class"] == "Harbor::Scorers::EvaluateJob" }
    assert Harbor::ScorerResult.find_by!(scorer: always, run: @run).queued?, "the claim is made before the judge is queued"
  end

  test "a pair already being judged is not queued again by the sampler" do
    scorer = new_scorer(sample_rate: 100)
    Harbor::ScorerResult.claim!(scorer:, run: @run)
    assert_no_enqueued_jobs(only: Harbor::Scorers::EvaluateJob) { Harbor::Scorers::SampleJob.perform_now(@run.id) }
    Harbor::ScorerResult.find_by!(scorer:, run: @run).update!(status: "ok", passed: true)
    assert_enqueued_jobs(1, only: Harbor::Scorers::EvaluateJob) { Harbor::Scorers::SampleJob.perform_now(@run.id) }
  end

  test "a run that has gone is nothing to sample" do
    new_scorer(sample_rate: 100)
    assert_no_enqueued_jobs { Harbor::Scorers::SampleJob.perform_now(0) }
  end
end
