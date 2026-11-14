require "test_helper"

# Proposals: the record and applying one, the targets a host adds, the line
# diff, reading a drafting run's answer, recording it, and the check that
# hands failures to the host's drafter.
class HarborProposalsTest < ActiveSupport::TestCase
  include HarborQuality

  ANSWER = <<~TEXT.freeze
    I read both transcripts.
    ```json
    {"pattern": "Both runs pushed without running the tests after their last edit.",
     "proposals": [
       {"target": "agent_prompt", "summary": "Require a test run after the last edit", "after": "Be careful.\\n\\nRun the tests after your final edit."},
       {"target": "agent_document", "path": "memory/testing.md", "summary": "Tests are not optional", "after": "Always run the tests."},
       {"target": "handbook_page", "summary": "Say so in the handbook", "path": "testing", "after": "Run the tests."},
       {"target": "handbook_page", "summary": "Nothing to write", "path": "empty", "after": ""},
       {"target": "agent_document", "path": "memory/testing.md", "summary": "unchanged", "after": "Tests are optional."},
       {"target": "agent_prompt", "summary": "unchanged", "after": "Be careful."},
       {"target": "somewhere_else", "summary": "not a target here", "after": "x"}
     ]}
    ```
  TEXT

  setup do
    @scorer = new_scorer(self_improvement: true, improvement_min_failures: 3, improvement_max_age_days: 7)
    @agent.agent_documents.create!(path: "memory/testing.md", body: "Tests are optional.")
  end

  def proposal(**attributes)
    Harbor::Proposal.create!({ agent_key: "writer", target_kind: "agent_prompt", summary: "Require a test run",
                               before: "Be careful.", after: "Be careful.\nRun the tests." }.merge(attributes))
  end

  def register_handbook
    Harbor::Proposals.register_target "handbook_page",
      label: ->(proposal) { "handbook · #{proposal.document_path}" },
      build: ->(entry, draft) { { document_path: entry["path"], after: entry["after"], regressions_addressed: "#{draft.pattern} (handbook)" } if entry["after"].present? }
  end

  # --- the record ---

  test "a proposal needs a known target, a status and a summary, and a document proposal its path" do
    assert proposal.valid?
    assert_not Harbor::Proposal.new(agent_key: "writer", target_kind: "handbook_page", summary: "x").valid?
    assert_not Harbor::Proposal.new(agent_key: "writer", target_kind: "agent_prompt", summary: "").valid?
    assert_not Harbor::Proposal.new(agent_key: "writer", target_kind: "agent_prompt", summary: "x", status: "merged").valid?
    assert_not Harbor::Proposal.new(agent_key: "writer", target_kind: "agent_document", summary: "x").valid?
    assert Harbor::Proposal.new(agent_key: "writer", target_kind: "agent_document", summary: "x", document_path: "a.md").valid?
  end

  test "applying a prompt proposal writes the agent's prompt and records when and who" do
    user = Struct.new(:id).new(42)
    applied = proposal.apply!(by: user)
    assert_equal "Be careful.\nRun the tests.", @agent.reload.system_prompt
    assert_equal [ "applied", 42 ], [ applied.status, applied.applied_by_user_id ]
    assert_not_nil applied.applied_at
    assert_not applied.applicable?
    assert_nil applied.applied_by_name, "Harbor has no user to name; a host's subclass does"
  end

  test "applying works for a user Harbor can't number" do
    proposal.apply!(by: Struct.new(:name).new("Sam"))
    assert_equal "applied", Harbor::Proposal.last.status
    assert_nil Harbor::Proposal.last.applied_by_user_id
  end

  test "a document proposal replaces the document, or creates it when it is new" do
    proposal(target_kind: "agent_document", document_path: "memory/testing.md", before: "Tests are optional.", after: "Always run the tests.").apply!(by: nil)
    assert_equal "Always run the tests.", @agent.agent_documents.find_by!(path: "memory/testing.md").body
    proposal(target_kind: "agent_document", document_path: "memory/new.md", before: "", after: "A new note.").apply!(by: nil)
    assert_equal "A new note.", @agent.agent_documents.find_by!(path: "memory/new.md").body
  end

  test "a proposal whose target changed since it was made refuses to apply" do
    stale = proposal(before: "Something older.")
    assert stale.drifted?
    error = assert_raises(ArgumentError) { stale.apply!(by: nil) }
    assert_equal "writer · system prompt changed since this proposal was made — dismiss it and run the check again", error.message
    assert_equal [ "proposed", "Be careful." ], [ stale.reload.status, @agent.reload.system_prompt ]
  end

  test "only a proposed change to an agent that still exists applies here" do
    gone = proposal(agent_key: "nobody")
    assert_not gone.applicable?
    assert_raises(ArgumentError) { gone.apply!(by: nil) }
    dismissed = proposal.tap(&:dismiss!)
    assert_equal "dismissed", dismissed.status
    assert_not_nil dismissed.dismissed_at
    assert_raises(ArgumentError) { dismissed.apply!(by: nil) }
  end

  test "a target is named for what it changes" do
    assert_equal "writer · system prompt", proposal.target_label
    assert_equal "writer · memory/testing.md", proposal(target_kind: "agent_document", document_path: "memory/testing.md").target_label
  end

  test "a proposal names the runs it was drafted from, and its results are let go when it is deleted" do
    result = failure(@scorer)
    made = proposal(evidence: { "run_ids" => [ result.run_id, 0 ] })
    result.update!(proposal: made)
    assert_equal [ result.run ], made.evidence_runs.to_a
    assert_equal [ result ], made.scorer_results.to_a
    made.destroy
    assert_nil result.reload.proposal_id
  end

  # --- a host's targets ---

  test "a host registers targets of its own, with a label and a way to build one" do
    assert_equal %w[agent_prompt agent_document], Harbor::Proposals.target_kinds
    register_handbook
    Harbor::Proposals.register_target "policy", label: "the policy"
    Harbor::Proposals.register_target "plain"
    assert_equal %w[agent_prompt agent_document handbook_page policy plain], Harbor::Proposals.target_kinds

    page = proposal(target_kind: "handbook_page", document_path: "testing", before: nil)
    assert_equal "handbook · testing", page.target_label
    assert_equal "the policy", proposal(target_kind: "policy").target_label
    assert_equal "Plain", proposal(target_kind: "plain").target_label
    assert_not page.agent_target?
    assert_not page.applicable?, "Harbor applies only an agent's own text"
    assert_not page.drifted?
    assert_raises(ArgumentError) { page.apply!(by: nil) }
    assert_nil Harbor::Proposals.target("agent_prompt")
  end

  test "a target is registered once, and Harbor's own can't be taken" do
    register_handbook
    assert_raises(ArgumentError) { Harbor::Proposals.register_target "handbook_page" }
    assert_raises(ArgumentError) { Harbor::Proposals.register_target "agent_prompt" }
  end

  # --- the diff ---

  test "the line diff marks what stayed, went and came" do
    diff = Harbor::Proposals::LineDiff.call("a\nb\nc", "a\nc\nd")
    assert_equal [ [ :same, "a" ], [ :del, "b" ], [ :same, "c" ], [ :add, "d" ] ], diff
    assert Harbor::Proposals::LineDiff.changed?(diff)
    assert_not Harbor::Proposals::LineDiff.changed?(Harbor::Proposals::LineDiff.call("a\nb", "a\nb"))
    assert_equal [ [ :add, "new" ] ], Harbor::Proposals::LineDiff.call(nil, "new")
  end

  test "a very long text is shown as replaced whole" do
    long = Array.new(Harbor::Proposals::LineDiff::MAX_LINES + 1) { |i| "line #{i}" }.join("\n")
    diff = Harbor::Proposals::LineDiff.call(long, "short")
    assert_equal [ :del ] * (Harbor::Proposals::LineDiff::MAX_LINES + 1) + [ :add ], diff.map(&:first)
  end

  # --- reading and recording an answer ---

  test "an answer is the last block with a proposals list, keeping the entries whose target is known" do
    register_handbook
    verdict = Harbor::Proposals::Verdict.parse(ANSWER)
    assert_match "pushed without running the tests", verdict.pattern
    assert_equal %w[agent_prompt agent_document handbook_page handbook_page agent_document agent_prompt], verdict.proposals.map { |p| p["target"] }
    empty = Harbor::Proposals::Verdict.parse("```json\n{\"pattern\": \"The scorer is wrong.\", \"proposals\": []}\n```")
    assert_equal [ "The scorer is wrong.", [] ], [ empty.pattern, empty.proposals ]
    assert_nil Harbor::Proposals::Verdict.parse("```json\n{\"pattern\": \"no list\"}\n```")
    assert_nil Harbor::Proposals::Verdict.parse("I looked but could not decide.")
  end

  test "an answer becomes proposals with their evidence, and the failures it covered are reviewed" do
    register_handbook
    results = 2.times.map { failure(@scorer, claimed_at: Time.current) }
    run = Harbor::Run.create!(skill: "self-improvement", status: "ok", output: { "exit_code" => 0 })

    created = Harbor::Proposals::Recorder.call(run:, scorer: @scorer, agent: @agent, results:, text: ANSWER)

    assert_equal %w[agent_prompt agent_document handbook_page], created.map(&:target_kind), "an entry that changes nothing is dropped"
    assert_equal created, Harbor::Proposal.order(:id).to_a
    prompt, document, page = created
    assert_equal [ @scorer, "writer", run, "proposed", "Require a test run after the last edit", "Be careful." ],
                 [ prompt.scorer, prompt.agent_key, prompt.run, prompt.status, prompt.summary, prompt.before ]
    assert_match "Run the tests after your final edit.", prompt.after
    assert_match "pushed without running the tests", prompt.regressions_addressed
    assert_equal({ "run_ids" => results.map(&:run_id), "scorer_result_ids" => results.map(&:id) }, prompt.evidence)
    assert_equal [ "memory/testing.md", "Tests are optional.", "Always run the tests." ], [ document.document_path, document.before, document.after ]
    assert_equal [ "testing", "Run the tests.", "Say so in the handbook" ], [ page.document_path, page.after, page.summary ]
    assert_match(/\(handbook\)\z/, page.regressions_addressed, "what a host's build returns wins")
    assert_equal prompt.evidence, page.evidence

    results.each do |result|
      result.reload
      assert_not_nil result.reviewed_at
      assert_nil result.claimed_at
      assert_equal prompt.id, result.proposal_id
    end
    assert_equal [ created.map(&:id), 0 ], [ run.reload.output["proposals"], run.output["exit_code"] ]
    assert_match "pushed without", run.output["pattern"]
    assert_equal "ok", run.status
  end

  test "an answer that proposes nothing still marks the batch reviewed" do
    results = [ failure(@scorer) ]
    run = Harbor::Run.create!(skill: "self-improvement", status: "ok")
    created = Harbor::Proposals::Recorder.call(run:, scorer: @scorer, agent: @agent, results:,
                                               text: "```json\n{\"pattern\": \"The scorer is wrong.\", \"proposals\": []}\n```")
    assert_equal [], created
    assert_not_nil results.first.reload.reviewed_at
    assert_nil results.first.proposal_id
    assert_equal [], run.reload.output["proposals"]
  end

  test "with no answer to read the run is an error and the failures go back to the next check" do
    results = [ failure(@scorer, claimed_at: Time.current) ]
    run = Harbor::Run.create!(skill: "self-improvement", status: "ok", output: { "text" => "I looked." })
    assert_nil Harbor::Proposals::Recorder.call(run:, scorer: @scorer, agent: @agent, results:, text: "I looked but could not decide.")
    assert_equal [ "error", { "text" => "I looked." } ], [ run.reload.status, run.output ]
    assert_match "without a proposals block", run.error
    assert_equal 0, Harbor::Proposal.count
    assert_nil results.first.reload.reviewed_at
    assert_nil results.first.claimed_at
  end

  test "a drafter whose run failed releases its batch" do
    results = [ failure(@scorer, claimed_at: Time.current) ]
    Harbor::Proposals::Recorder.release!(results)
    assert_nil results.first.reload.claimed_at
    assert_includes Harbor::ScorerResult.failed.unreviewed, results.first
  end

  # --- the check ---

  # Stands in for a host's drafter: remembers what it was handed.
  def drafter
    handed = []
    Harbor.config.proposal_drafter = ->(**batch) { handed << batch }
    handed
  end

  def check(trigger_source: "cron")
    run = Harbor::Run.create!(skill: Harbor::Proposals::CheckJob::SKILL, trigger_source:)
    Harbor::Proposals::CheckJob.perform_now(run.id)
    run.reload
  end

  test "below the threshold and young, nothing is handed over; at the threshold, one batch per agent" do
    handed = drafter
    2.times { failure(@scorer) }
    run = check
    assert_equal [ "ok", 1, [] ], [ run.status, run.output["groups"], run.output["dispatched"] ]
    assert_empty handed
    assert_includes Harbor::LiveLog.read(run.live_log_path), "2 failure(s), oldest 1d ago — waiting for 3 or 7 days"

    third = failure(@scorer)
    other = failure(@scorer, agent_key: "editor")
    run = check
    batch = handed.sole
    assert_equal [ @scorer, "writer", run ], batch.values_at(:scorer, :agent_key, :check_run)
    assert_includes batch[:result_ids], third.id
    assert_not_includes batch[:result_ids], other.id
    assert_equal [ { "scorer" => @scorer.name, "agent" => "writer", "failures" => 3 } ], run.output["dispatched"]
    assert_equal 2, run.output["groups"]
  end

  test "one old failure is enough, reviewed and passed results don't count, and a check by hand takes any group" do
    handed = drafter
    failure(@scorer, scored_at: 8.days.ago)
    failure(@scorer, agent_key: "editor", reviewed_at: 1.hour.ago, scored_at: 8.days.ago)
    failure(@scorer, agent_key: "planner", passed: true, scored_at: 8.days.ago)
    check
    assert_equal %w[writer], handed.map { |batch| batch[:agent_key] }

    handed.clear
    failure(@scorer, agent_key: "editor", scored_at: 1.hour.ago)
    check(trigger_source: "manual")
    assert_equal %w[editor], handed.map { |batch| batch[:agent_key] }, "the first batch is still claimed by the first check"
  end

  test "a batch handed over is claimed, so an overlapping check doesn't hand it over again" do
    handed = drafter
    3.times { failure(@scorer) }
    check
    assert_equal 1, handed.size
    assert Harbor::ScorerResult.where(scorer: @scorer).all? { |result| result.claimed_at.present? }
    check(trigger_source: "manual")
    assert_equal 1, handed.size, "still one"
    Harbor::ScorerResult.where(scorer: @scorer).update_all(claimed_at: 3.hours.ago)
    check(trigger_source: "manual")
    assert_equal 2, handed.size, "a stale claim is offered again"
  end

  test "a batch is no larger than one drafting run is shown" do
    handed = drafter
    (Harbor::Proposals::BATCH + 3).times { failure(@scorer) }
    check
    assert_equal Harbor::Proposals::BATCH, handed.sole[:result_ids].size
    assert_equal 3, Harbor::ScorerResult.failed.unreviewed.count, "the rest wait for the next check"
  end

  test "with no scorer flagged the check is a skipped run that says so" do
    drafter
    @scorer.update!(self_improvement: false)
    run = check
    assert_equal "skipped", run.status
    assert_equal "No enabled scorer has self-improvement switched on (see /factory/scorers).", run.error
  end

  test "with no drafter configured the check is an error that says what the site has to do, and claims nothing" do
    assert_nil Harbor.config.proposal_drafter
    3.times { failure(@scorer) }
    run = check
    assert_equal "error", run.status
    assert_match "No drafter is configured", run.error
    assert_match "Harbor.config.proposal_drafter", run.error
    assert_equal 3, Harbor::ScorerResult.failed.unreviewed.count
  end

  test "a drafter that raises is an error on the check's run" do
    Harbor.config.proposal_drafter = ->(**) { raise "the queue is down" }
    3.times { failure(@scorer) }
    run = check
    assert_equal [ "error", "RuntimeError: the queue is down" ], [ run.status, run.error ]
  end

  test "a check whose run is already over does nothing" do
    handed = drafter
    3.times { failure(@scorer) }
    run = Harbor::Run.create!(skill: Harbor::Proposals::CheckJob::SKILL, status: "canceled")
    Harbor::Proposals::CheckJob.perform_now(run.id)
    assert_empty handed
    assert_equal "canceled", run.reload.status
  end
end
