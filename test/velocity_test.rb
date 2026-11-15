require "test_helper"

# Velocity's building blocks: the tabs and tiles a host declares beside
# Harbor's, the period a page is about, and the three sets of figures, each
# read from runs and scorer results.
class HarborVelocityRegistryTest < ActiveSupport::TestCase
  include HarborOverviewSetup

  test "Harbor's tabs are Runs, Spending and Scorers, each with a partial of its own" do
    assert_equal [ %w[runs Runs harbor/velocity/runs], %w[spending Spending harbor/velocity/spending],
                   %w[scorers Scorers harbor/velocity/scorers] ], Harbor::Velocity.tabs.map { |tab| [ tab.key, tab.label, tab.partial ] }
    assert_equal %w[7d 30d 90d 12w 6m], Harbor::Velocity::RANGES.keys
    assert_equal "12w", Harbor::Velocity::DEFAULT_RANGE
  end

  test "a host's tab sits where it is declared, and a tab of Harbor's can be taken away" do
    Harbor::Velocity.tab "tickets", label: "Tickets", partial: "host/velocity/tickets", before: "runs"
    Harbor::Velocity.tab :orders, label: "Orders", partial: "host/velocity/orders", after: :spending
    Harbor::Velocity.tab "last", label: "Last", partial: "host/velocity/last"
    assert_equal %w[tickets runs spending orders scorers last], Harbor::Velocity.tabs.map(&:key)
    Harbor::Velocity.remove_tab "runs"
    Harbor::Velocity.tab "tickets", label: "Desk", partial: "host/velocity/tickets", after: "scorers"
    assert_equal %w[spending orders scorers tickets last], Harbor::Velocity.tabs.map(&:key)
    assert_equal "Desk", Harbor::Velocity.tabs[3].label
    assert_raises(ArgumentError) { Harbor::Velocity.tab "x", label: "X", partial: "x", after: "nowhere" }
    assert_raises(ArgumentError) { Harbor::Velocity.tab "x", label: "X", partial: "x", after: "runs", before: "runs" }
  end

  test "a host's tiles are kept per tab" do
    Harbor::Velocity.tile("spending", :per_ticket, label: "Per ticket", note: "median", after: :runs) { |_period| "$2.00" }
    Harbor::Velocity.tile(:runs, :tickets, label: "Tickets") { |_period| "7" }
    assert_equal [ [ :per_ticket, "Per ticket", "median", :runs ] ],
                 Harbor::Velocity.tiles("spending").map { |tile| [ tile.key, tile.label, tile.note, tile.after ] }
    assert_equal [ :tickets ], Harbor::Velocity.tiles("runs").map(&:key)
    assert_empty Harbor::Velocity.tiles("scorers")
  end

  test "a period keeps what was built for it once" do
    period = Harbor::Velocity::Period.new(since: 7.days.ago)
    built = 0
    2.times { assert_equal :figures, period.fetch(:figures) { built += 1; :figures } }
    assert_equal 1, built
    assert_equal period.since..period.now, period.range
  end
end

class HarborVelocityFiguresTest < ActiveSupport::TestCase
  include HarborOverviewSetup

  def scorer(**attrs)
    Harbor::Scorer.create!({ name: "Ran the tests", judge_instructions: "Did it?", model_alias: @alias, sample_rate: 0, pass_threshold: 1.0,
                             classifications: [ { "label" => "pass", "score" => 1.0 }, { "label" => "fail", "score" => 0.0 } ] }.merge(attrs))
  end

  test "runs: how many, how they ended, how long, by week, agent, task type and runtime" do
    travel_to Time.zone.local(2026, 11, 12, 10) do
      laptop = Harbor::Runtime.create!(key: "laptop", name: "Laptop", backend: "orca", config: { "repo" => "name:app" })
      finished("review", minutes: 2, agent_key: "writer", runtime_id: laptop.id)
      finished("review", minutes: 4, agent_key: "writer", runtime_id: laptop.id)
      finished("review", minutes: 9, agent_key: "writer", status: "error")
      finished("rebase", minutes: 1, agent_key: "planner", status: "timeout", started: 9.days.ago)
      parent = finished("triage", minutes: 6, agent_key: "planner", started: 9.days.ago)
      finished("triage", minutes: 30, agent_key: "planner", started: 9.days.ago, parent_run_id: parent.id)
      finished("review", minutes: 2, started: 40.days.ago)
      Harbor::Run.create!(task_type: "review", status: "running", agent_key: "writer")
      Harbor::Run.create!(loader: "nightly", status: "queued")

      runs = Harbor::Velocity::Runs.new(since: 14.days.ago.beginning_of_day)
      assert_equal [ 8, 4, 2, 2, 33 ], [ runs.count, runs.ok, runs.failed, runs.active, runs.failure_rate ]
      assert_in_delta 300.0, runs.median_seconds, 0.01 # 2m, 4m, 6m, 30m
      assert_equal [ [ Date.new(2026, 10, 26), 0 ], [ Date.new(2026, 11, 2), 3 ], [ Date.new(2026, 11, 9), 5 ] ], runs.weekly
      assert_equal({ [ "writer", "ok" ] => 2, [ "writer", "error" ] => 1, [ "writer", "running" ] => 1,
                     [ "planner", "timeout" ] => 1, [ "planner", "ok" ] => 2 }, runs.by_agent)
      assert_equal [ [ "review", 4 ], [ "rebase", 1 ], [ "triage", 1 ] ], runs.by_task_type, "a delegated run isn't counted beside its parent"
      assert_equal [ [ "Laptop", 2 ] ], runs.by_runtime

      none = Harbor::Velocity::Runs.new(since: 1.minute.from_now)
      assert_equal [ 0, nil, nil, [] ], [ none.count, none.failure_rate, none.median_seconds, none.by_task_type ]
    end
  end

  test "spending: top-level runs and scorer judges, by week, agent and model" do
    travel_to Time.zone.local(2026, 11, 12, 10) do
      parent = finished("review", minutes: 2, cost: 3.0, agent_key: "writer", model: "claude-sonnet-5-5")
      finished("review", minutes: 2, cost: 1.0, agent_key: "writer", parent_run_id: parent.id, model: "claude-haiku-5-5")
      finished(nil, minutes: 1, cost: 0.02, skill: Harbor::Scorer::JUDGE_SKILL, parent_run_id: parent.id, model: "claude-haiku-5-5")
      finished("triage", minutes: 2, cost: 0.5, agent_key: "planner", started: 9.days.ago)
      finished("triage", minutes: 2, agent_key: "planner")
      finished("review", minutes: 2, cost: 99, started: 40.days.ago)

      spending = Harbor::Velocity::Spending.new(since: 14.days.ago.beginning_of_day)
      assert_in_delta 3.52, spending.total, 0.001, "a delegated run's cost is in its parent's, and a judge has a bill of its own"
      assert_equal [ 4, 3 ], [ spending.run_count, spending.costed_count ]
      assert_equal [ [ Date.new(2026, 10, 26), 0.0 ], [ Date.new(2026, 11, 2), 0.5 ], [ Date.new(2026, 11, 9), 3.02 ] ], spending.weekly
      assert_equal [ [ "writer", 3.0, 1 ], [ "planner", 0.5, 2 ] ], spending.by_agent
      assert_equal [ [ "claude-sonnet-5-5", 3.0, 1 ], [ nil, 0.5, 1 ], [ "claude-haiku-5-5", 0.02, 1 ] ],
                   spending.by_model.map { |model, cost, count| [ model, cost.to_f, count ] }
    end
  end

  test "scoring: each scorer's verdicts over the range, and what the judging cost" do
    careful = scorer
    quiet = scorer(name: "Quiet", enabled: false)
    runs = Array.new(4) { finished("review", minutes: 1, agent_key: "writer") }
    judge = finished(nil, minutes: 1, cost: 0.03, skill: Harbor::Scorer::JUDGE_SKILL, parent_run_id: runs[0].id)
    finished(nil, minutes: 1, cost: 5, skill: Harbor::Scorer::JUDGE_SKILL, parent_run_id: runs[0].id, started: 40.days.ago)
    Harbor::ScorerResult.create!(scorer: careful, run: runs[0], judge_run: judge, status: "ok", passed: true, classification: "pass", score: 1, scored_at: 1.day.ago)
    Harbor::ScorerResult.create!(scorer: careful, run: runs[1], status: "ok", passed: false, classification: "fail", score: 0, scored_at: 2.days.ago)
    Harbor::ScorerResult.create!(scorer: careful, run: runs[2], status: "ok", passed: false, classification: "fail", score: 0, scored_at: 3.days.ago)
    Harbor::ScorerResult.create!(scorer: careful, run: runs[3], status: "error")
    old = finished("review", minutes: 1, started: 40.days.ago)
    Harbor::ScorerResult.create!(scorer: careful, run: old, status: "ok", passed: true, classification: "pass", score: 1, scored_at: 40.days.ago)

    scoring = Harbor::Velocity::Scoring.new(since: 14.days.ago.beginning_of_day)
    assert_equal [ quiet, careful ], scoring.scorers.to_a, "by position, then name"
    summary = scoring.summary(careful)
    assert_equal [ 3, 1, 2, 33, 1 ], summary.values_at(:total, :passed, :failed, :pass_rate, :errors)
    assert_equal [ [ "fail", 2 ], [ "pass", 1 ] ], summary[:by_label]
    assert_equal 3, summary[:series].size
    assert_equal [ 0, nil ], scoring.summary(quiet).values_at(:total, :pass_rate)
    assert_equal 1, scoring.judge_count
    assert_in_delta 0.03, scoring.judge_spend, 0.001
  end
end
