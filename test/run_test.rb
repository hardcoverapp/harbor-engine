require "test_helper"

class HarborRunTest < ActiveSupport::TestCase
  # What a host does to add its own behaviour: a subclass on the same table.
  class HostRun < Harbor::Run
    def label = "host: #{super}"
  end

  setup { Harbor::Run.delete_all }

  def run_with(**attrs) = Harbor::Run.create!({ skill: "nightly-report" }.merge(attrs))

  test "a run starts queued and manual, and moves through to a result" do
    run = run_with
    assert run.queued?
    assert run.trigger_manual?
    assert run.pending?
    assert_not run.finished?

    run.start!
    assert run.running?
    started = run.started_at
    assert started

    run.start!
    assert_equal started, run.started_at, "a second start keeps the first start time"

    run.finish!(status: "ok", output: { "rows" => 3 })
    assert run.ok?
    assert run.finished?
    assert_equal({ "rows" => 3 }, run.output)
    assert_operator run.duration_seconds, :>=, 0
  end

  test "finishing without output keeps what was already there" do
    run = run_with(output: { "kept" => true })
    run.finish!(status: "error", error: "boom")
    assert_equal({ "kept" => true }, run.output)
    assert run.failed?
    assert_equal "boom", run.error
  end

  test "an unknown status is refused" do
    assert_raises(ArgumentError) { run_with(status: "exploded") }
  end

  test "the label names the loader, the skill, or the agent and task" do
    assert_equal "Db Backup", Harbor::Run.new(loader: "db-backup").label
    assert_equal "nightly-report", Harbor::Run.new(skill: "nightly-report").label
    assert_equal "ada · pr_review", Harbor::Run.new(agent_key: "ada", task_type: "pr_review").label
    assert_equal "(unlabelled)", Harbor::Run.new.label
  end

  test "cost prefers the reported actual over the estimate" do
    assert_equal 2, Harbor::Run.new(cost_usd_actual: 2, cost_usd_estimate: 1).cost_usd
    assert_equal 1, Harbor::Run.new(cost_usd_estimate: 1).cost_usd
    assert_nil Harbor::Run.new.cost_usd
  end

  test "the token summary keeps cached input apart" do
    run = Harbor::Run.new(input_tokens: 21_000, cache_read_tokens: 388_000, cache_creation_tokens: 12_000, output_tokens: 19_400)
    assert_equal "421k in (388k cached) / 19k out", run.token_summary
    assert_equal "900 in / 40 out", Harbor::Run.new(input_tokens: 900, output_tokens: 40).token_summary
    assert_nil Harbor::Run.new.token_summary
  end

  test "claim! takes an idempotency key once" do
    first = Harbor::Run.claim!(idempotency_key: "delivery-1/review", skill: "review")
    assert first.persisted?
    assert_nil Harbor::Run.claim!(idempotency_key: "delivery-1/review", skill: "review")
    assert Harbor::Run.claim!(idempotency_key: nil, skill: "review").persisted?
    assert_equal 2, Harbor::Run.count
  end

  test "only one live run can hold a join key; a finished one frees it" do
    held = run_with(join_key: "pr:12")
    assert_raises(ActiveRecord::RecordNotUnique) { run_with(join_key: "pr:12") }
    held.finish!(status: "ok")
    assert run_with(join_key: "pr:12").persisted?
  end

  test "a failed run can be marked done, once" do
    run = run_with(status: "error")
    assert run.resolvable?
    run.update!(resolved_at: Time.current)
    assert run.resolved?
    assert_not run.resolvable?
    assert_not run_with(status: "ok").resolvable?
    assert_equal [ run.id ], Harbor::Run.where.not(resolved_at: nil).ids
    assert_not_includes Harbor::Run.unresolved.ids, run.id
  end

  test "what a Stop button can interrupt" do
    assert Harbor::Run.new(status: "queued", task_type: "pr_review").cancelable?
    assert_not Harbor::Run.new(status: "queued", loader: "blog").cancelable?
    assert Harbor::Run.new(status: "running", agent_key: "ada").cancelable?
    assert_not Harbor::Run.new(status: "running", loader: "blog").cancelable?
    assert_not Harbor::Run.new(status: "ok", agent_key: "ada").cancelable?
  end

  test "scopes: pending, live, top level, most recent first" do
    old = run_with(status: "ok", started_at: 2.hours.ago)
    live = run_with(status: "running", started_at: 1.minute.ago)
    waiting = run_with(status: "waiting_for_model")
    child = run_with(parent_run: live, status: "ok")

    assert_equal [ waiting.id ], Harbor::Run.pending.ids
    assert_equal [ live.id, waiting.id ].sort, Harbor::Run.queued_or_running.ids.sort
    assert_not_includes Harbor::Run.top_level.ids, child.id
    assert_equal old.id, Harbor::Run.recent.to_a.last.id
    assert_equal [ child.id ], live.child_runs.ids
    assert_equal live, child.parent_run
  end

  test "events belong to a run, in order, and go with it" do
    run = run_with
    run.run_events.create!(seq: 2, event_type: "assistant", tool_name: "Bash", summary: "ran tests", occurred_at: Time.current)
    run.run_events.create!(seq: 1, event_type: "system", summary: "started", occurred_at: Time.current)
    assert_equal %w[started ran\ tests], run.run_events.ordered.pluck(:summary)
    assert_equal [ "Bash" ], run.run_events.tool_uses.pluck(:tool_name)
    assert_raises(ActiveRecord::RecordNotUnique) { run.run_events.create!(seq: 1, event_type: "system", occurred_at: Time.current) }
    run.destroy!
    assert_equal 0, Harbor::RunEvent.count
  end

  test "a host's subclass shares the table and adds its own behaviour" do
    mine = HostRun.create!(skill: "nightly-report")
    assert_equal "runs", HostRun.table_name
    assert_equal "host: nightly-report", mine.label
    assert_equal "nightly-report", Harbor::Run.find(mine.id).label
    assert_equal [ mine.id ], HostRun.pending.ids
    assert HostRun.find(mine.id).is_a?(HostRun)
    assert_equal HostRun::STATUSES, Harbor::Run::STATUSES
  end

  test "Harbor uses the run class the host names" do
    assert_equal Harbor::Run, Harbor.run_class
    previous = Harbor.config.run_class
    Harbor.config.run_class = "HarborRunTest::HostRun"
    assert_equal HostRun, Harbor.run_class
  ensure
    Harbor.config.run_class = previous
  end
end
