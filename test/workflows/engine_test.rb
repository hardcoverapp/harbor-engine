require "test_helper"

# The engine replays a definition against recorded step runs. These walk
# definitions through Harbor's own step types and one registered by the test,
# with no agent: an agent step's Run is made by a stand-in and finished by
# hand, which is what a session's finisher does.
class HarborWorkflowsEngineTest < ActiveSupport::TestCase
  include HarborWorkflows
  include SingletonStub

  Control = Harbor::Workflows::Control

  setup { register_say }

  # Agent and verifier steps dispatch a queued Run and no session.
  def with_agent_runs(&block)
    with_stub(Harbor::Workflows::AgentStep, :dispatch!, ->(step_run) { fake_agent_run(step_run) }, &block)
  end

  def fake_agent_run(step_run)
    run = Harbor::Run.create!(skill: "workflow.test.#{step_run.step_key}", status: "queued", trigger_source: "workflow",
                              workflow_run_id: step_run.workflow_run_id, workflow_step_key: step_run.step_key,
                              idempotency_key: Harbor::Workflows::AgentStep.idempotency_key_for(step_run))
    step_run.update!(run:)
    run
  end

  def say(key, message, **more) = { "key" => key, "type" => "action", "action" => "say", "message" => message }.merge(more)

  MANUAL = [ { "kind" => "manual" } ].freeze

  test "actions and choices finish in one advance and pass outputs along" do
    wf = workflow(
      "triggers" => MANUAL,
      "steps" => [
        say("hello", "from {{trigger.sender}} on {{input.branch}}"),
        { "key" => "route", "type" => "choice", "branches" => [
          { "when" => { "path" => "steps.hello.said", "op" => "contains", "value" => "main" }, "steps" => [ say("yes", "heard {{steps.hello.said}}") ] }
        ], "otherwise" => [ say("no", "no") ] }
      ]
    )
    run = drain(start_workflow(wf, input: { "branch" => "main" }))
    assert_equal [ "succeeded", "live", "done" ], [ run.status, run.mode, run.phase ]
    assert_equal [ "from Sam on main", "heard from Sam on main" ], said
    assert_nil step_of(run, "no"), "the otherwise branch never ran"
    assert_equal "branch 1", step_of(run, "route").output["branch"]
    assert_equal "ok", run.context.dig("steps", "hello", "status")
  end

  test "a run knows its own id and address" do
    Harbor::Setting.set!(:runner_url, "https://harbor.example.com/")
    run = start_workflow(workflow("triggers" => MANUAL, "steps" => [ say("hello", "{{run.url}}") ]))
    assert_equal({ "id" => run.id, "url" => "https://harbor.example.com/factory/workflow_runs/#{run.id}" }, run.context["run"])

    Harbor.config.workflow_run_url = ->(workflow_run) { "https://hub.example.com/w/#{workflow_run.id}" }
    drain(run)
    said.clear
    again = drain(start_workflow(workflow("triggers" => MANUAL, "steps" => [ say("hello", "{{run.url}}") ])))
    assert_equal [ "https://hub.example.com/w/#{again.id}" ], said
  end

  test "a filter that passes lets the run carry on; one that fails stops it there, and cleanup still runs" do
    definition = {
      "triggers" => MANUAL,
      "steps" => [
        { "key" => "has_size", "type" => "filter", "name" => "Has a size", "when" => { "path" => "input.size", "op" => "present" } },
        { "key" => "big", "type" => "filter", "name" => "Big ones", "when" => { "path" => "input.size", "op" => "gt", "value" => "9000" } },
        say("after", "past both")
      ],
      "finally" => [ say("cleanup", "bye") ]
    }
    run = drain(start_workflow(workflow(definition), input: { "size" => 9101 }))
    assert_equal "succeeded", run.status
    assert_equal [ true, true ], [ step_of(run, "has_size").output["passed"], step_of(run, "big").output["passed"] ]
    assert_equal [ "past both", "bye" ], said

    said.clear
    run = drain(start_workflow(workflow(definition), input: { "size" => 12 }))
    assert_equal "succeeded", run.status, "a filter stopping the run isn't a failure"
    assert_equal false, step_of(run, "big").output["passed"]
    assert_nil step_of(run, "after"), "nothing after a failed filter runs"
    assert_equal [ "bye" ], said
    assert_match "Stopped at Big ones", run.note
  end

  test "an agent step waits for its Run, and a verifier's verdict routes the next step" do
    wf = workflow(
      "triggers" => MANUAL,
      "steps" => [
        { "key" => "review", "type" => "verifier", "agent" => "task:review", "slash_command" => "review {{input.branch}}", "verdicts" => %w[approve changes] },
        { "key" => "route", "type" => "choice", "branches" => [
          { "when" => { "path" => "steps.review.verdict", "op" => "eq", "value" => "changes" },
            "steps" => [ { "key" => "fix", "type" => "agent", "agent" => "writer", "prompt" => "Fix: {{steps.review.feedback}}" } ] }
        ] }
      ]
    )
    with_agent_runs do
      run = drain(start_workflow(wf, input: { "branch" => "main" }))
      assert_equal "running", run.status, "an agent at work is running, not waiting"
      assert_equal "review main", step_of(run, "review").input["slash_command"]

      finish_step_run(run, "review", text: "Looks off.\n```json\n{\"verdict\": \"changes\", \"feedback\": \"rename the column\"}\n```")
      run = drain(run)
      assert_equal "changes", step_of(run, "review").output["verdict"]
      assert_equal "Fix: rename the column", step_of(run, "fix").input["prompt"]

      finish_step_run(run, "fix", text: "done\n```json\n{\"branch\": \"fix-1\"}\n```")
      run = drain(run)
      assert_equal "succeeded", run.status
      assert_equal "fix-1", run.context.dig("steps", "fix", "branch"), "what the agent returned is there for later steps"
      assert_equal run.runs.find_by(workflow_step_key: "fix").id, run.context.dig("steps", "fix", "run_id")
    end
  end

  test "a failed agent step fails the run, unless the step says to carry on" do
    definition = ->(on_error) do
      { "triggers" => MANUAL,
        "steps" => [ { "key" => "fix", "type" => "agent", "agent" => "writer", "prompt" => "fix it", "on_error" => on_error }.compact, say("after", "carried on") ],
        "finally" => [ say("cleanup", "bye") ] }
    end
    with_agent_runs do
      run = drain(start_workflow(workflow(definition.call(nil))))
      finish_step_run(run, "fix", text: "the build is broken", ok: false)
      run = drain(run)
      assert_equal [ "failed", "error", "the build is broken" ], [ run.status, step_of(run, "fix").status, step_of(run, "fix").error ]
      assert_equal [ "bye" ], said, "cleanup ran; the step after the failure didn't"

      said.clear
      run = drain(start_workflow(workflow(definition.call("continue"))))
      finish_step_run(run, "fix", text: "the build is broken", ok: false)
      assert_equal "succeeded", drain(run).status
      assert_equal [ "carried on", "bye" ], said
    end
  end

  test "a host that retries a failed agent step keeps the step pending" do
    asked = []
    Harbor.config.workflow_step_retry = ->(run, step_run) { asked << [ run.id, step_run.step_key ]; asked.size == 1 }
    with_agent_runs do
      run = drain(start_workflow(workflow("triggers" => MANUAL, "steps" => [ { "key" => "fix", "type" => "agent", "agent" => "writer", "prompt" => "fix" } ])))
      first = run.runs.sole
      finish_step_run(run, "fix", text: "went away", ok: false)
      assert_equal "running", step_of(run, "fix").status, "the host said it will try again"
      assert_no_enqueued_jobs only: Harbor::Workflows::AdvanceJob

      # The host's retry: a new Run on the same step.
      retried = Harbor::Run.create!(skill: "retry", status: "queued", workflow_run_id: run.id, workflow_step_key: "fix")
      step_of(run, "fix").update!(run: retried)
      retried.finish!(status: "ok", output: { "text" => "pushed", "exit_code" => 0 })
      assert_equal "succeeded", drain(run).status
      assert_equal [ [ first.id, "fix" ], [ retried.id, "fix" ] ], asked
    end
  end

  test "a verifier without a verdict fails the run, and finally still cleans up" do
    wf = workflow("triggers" => MANUAL,
                  "steps" => [ { "key" => "review", "type" => "verifier", "agent" => "writer", "prompt" => "review", "verdicts" => %w[pass fail] } ],
                  "finally" => [ say("cleanup", "bye") ])
    with_agent_runs do
      run = drain(start_workflow(wf))
      finish_step_run(run, "review", text: "I have thoughts but no verdict")
      run = drain(run)
      assert_equal "failed", run.status
      assert_match(/no verdict from pass, fail/, step_of(run, "review").error)
      assert_equal "ok", step_of(run, "cleanup").status
    end
  end

  test "a verdict on a line of its own counts when there is no JSON block" do
    wf = workflow("triggers" => MANUAL,
                  "steps" => [ { "key" => "review", "type" => "verifier", "agent" => "writer", "prompt" => "review", "verdicts" => %w[pass fail] } ])
    with_agent_runs do
      run = drain(start_workflow(wf))
      finish_step_run(run, "review", text: "All good.\nVERDICT: PASS")
      run = drain(run)
      assert_equal [ "succeeded", "pass" ], [ run.status, step_of(run, "review").output["verdict"] ]
    end
  end

  test "a loop repeats until its condition passes, and one that runs out of passes ends exhausted" do
    loop_until = ->(value, max) do
      { "triggers" => MANUAL,
        "steps" => [ { "key" => "rounds", "type" => "loop", "max_iterations" => max,
                       "until" => { "path" => "steps.ping.said", "op" => "eq", "value" => value },
                       "steps" => [ say("ping", "pass {{loop.rounds.iteration}}") ] },
                     say("after", "{{steps.rounds.result}} after {{steps.rounds.iterations}}") ] }
    end
    run = drain(start_workflow(workflow(loop_until.call("pass 2", 5))))
    assert_equal({ "result" => "converged", "iterations" => 2 }, step_of(run, "rounds").output)
    assert_equal [ "pass 1", "pass 2", "converged after 2" ], said
    assert_equal %w[rounds[1]/ rounds[2]/], run.step_runs.where(step_key: "ping").order(:id).map(&:scope)

    said.clear
    run = drain(start_workflow(workflow(loop_until.call("never", 2))))
    assert_equal({ "result" => "exhausted", "iterations" => 2 }, step_of(run, "rounds").output)
    assert_equal [ "pass 1", "pass 2", "exhausted after 2" ], said
  end

  test "a step that raises is an error with the reason, and fails the run" do
    run = drain(start_workflow(workflow("triggers" => MANUAL, "steps" => [ say("boom", "fail"), say("after", "never") ])))
    assert_equal "failed", run.status
    assert_equal "ArgumentError: told to fail", step_of(run, "boom").error
    assert_nil step_of(run, "after")
  end

  test "advancing again replays what is recorded and runs nothing twice" do
    run = drain(start_workflow(workflow("triggers" => MANUAL, "steps" => [ say("hello", "once"), { "key" => "ok", "type" => "approval" }, say("after", "then") ])))
    assert_equal "waiting", run.status
    3.times { Harbor::Workflows::Engine.advance!(run.id) }
    assert_equal [ "once" ], said

    assert Control.decide!(run, step_run_id: step_of(run, "ok").id, approved: true)
    run = drain(run)
    Harbor::Workflows::Engine.advance!(run.id)
    assert_equal [ "succeeded", %w[once then] ], [ run.reload.status, said ]
  end

  test "a dry run records what a step would do, and runs only the steps that act on nothing outside" do
    Harbor::Workflows.register_step "action", action: "think", label: "Think", runner: "HarborWorkflows::Recorder", side_effect: false
    wf = workflow({ "triggers" => MANUAL,
                    "steps" => [ say("hello", "hi {{input.branch}}"),
                                 { "key" => "muse", "type" => "action", "action" => "think", "message" => "hmm" },
                                 { "key" => "work", "type" => "agent", "agent" => "writer", "prompt" => "do it" },
                                 { "key" => "ok", "type" => "approval" } ] }, mode: "dry_run")
    run = drain(start_workflow(wf, input: { "branch" => "main" }))
    assert_equal [ "succeeded", "dry_run" ], [ run.status, run.mode ]
    assert_equal [ "hmm" ], said, "only the step with no side effect ran"
    assert_equal "hi main", step_of(run, "hello").output.dig("would", "message")
    assert_equal %w[skipped ok skipped skipped], %w[hello muse work ok].map { |key| step_of(run, key).status }
    assert_empty run.runs
  end

  test "a live workflow only dry-runs while workflows are switched off, or when asked to" do
    wf = workflow("triggers" => MANUAL, "steps" => [ say("hello", "hi") ])
    assert_equal "dry_run", start_workflow(wf, force_dry_run: true).mode
    Harbor::Setting.set!(:workflows_enabled, false)
    assert_equal "dry_run", start_workflow(wf).mode
  end

  test "a dry run ends at a step registered to stop one" do
    Harbor::Workflows.register_step "pause", label: "Pause", runner: "HarborWorkflows::Recorder", dry_run_stop: "which waits for the weekend"
    wf = workflow({ "triggers" => MANUAL, "steps" => [ { "key" => "rest", "type" => "pause", "name" => "Rest" }, say("never", "never") ] }, mode: "dry_run")
    run = drain(start_workflow(wf))
    assert_equal [ "succeeded", "Dry run: stopped at Rest, which waits for the weekend." ], [ run.status, run.note ]
    assert_nil step_of(run, "never")
  end

  test "an approval waits for a person; cancel stops the run and runs cleanup" do
    wf = workflow("triggers" => MANUAL,
                  "steps" => [ { "key" => "ok", "type" => "approval", "prompt" => "Ship?" }, say("after", "{{steps.ok.decision}} by {{steps.ok.by}}") ],
                  "finally" => [ say("cleanup", "cleanup") ])
    user = Struct.new(:name, :email).new("Sam Settings", "sam@example.com")
    run = drain(start_workflow(wf))
    assert_equal [ "waiting", "Ship?" ], [ run.status, step_of(run, "ok").output["prompt"] ]
    refute Control.decide!(run, step_run_id: run.step_runs.create!(step_key: "x", step_type: "action", scope: "x").id, approved: true)
    assert Control.decide!(run, step_run_id: step_of(run, "ok").id, approved: true, user:, note: "go")
    run = drain(run)
    assert_equal "succeeded", run.status
    assert_equal [ "approved by Sam Settings", "cleanup" ], said
    assert_equal "go", step_of(run, "ok").output["note"]

    said.clear
    second = drain(start_workflow(wf))
    assert Control.cancel!(second, user:)
    second = drain(second)
    assert_equal [ "canceled", "canceled", "canceled by Sam Settings" ], [ second.status, step_of(second, "ok").status, step_of(second, "ok").error ]
    assert_equal [ "cleanup" ], said
    refute Control.cancel!(second), "a finished run has nothing to cancel"
  end

  test "canceling stops a step's Run that is still going: Harbor's way, or the host's" do
    wf = workflow("triggers" => MANUAL, "steps" => [ { "key" => "work", "type" => "agent", "agent" => "writer", "prompt" => "do it" } ])
    with_agent_runs do
      run = drain(start_workflow(wf))
      Harbor::Run.find(run.runs.sole.id).update!(task_type: "workflow")
      Control.cancel!(run)
      assert_equal [ "canceled", "canceled while queued" ], run.runs.sole.then { |r| [ r.status, r.error ] }
      assert_equal "canceled", drain(run).status

      stopped = []
      Harbor.config.workflow_run_cancel = ->(step_run, user) { stopped << [ step_run.id, user ] }
      again = drain(start_workflow(wf))
      Control.cancel!(again, user: nil)
      assert_equal [ [ again.runs.sole.id, nil ] ], stopped
      assert_equal "canceled", drain(again).status
    end
  end

  test "a call step runs the child workflow and gets its result back" do
    child = workflow({ "triggers" => MANUAL, "steps" => [ say("inner", "child got {{input.branch}} from {{trigger.sender}}") ] }, key: "child-#{SecureRandom.hex(3)}")
    parent = workflow("triggers" => MANUAL,
                      "steps" => [ { "key" => "go", "type" => "call", "workflow" => child.key, "input" => { "branch" => "{{input.branch}}-2" } },
                                   say("after", "{{steps.go.result}}: {{steps.go.steps.inner.said}}") ])
    run = drain(start_workflow(parent, input: { "branch" => "main" }))
    assert_equal "succeeded", run.status
    kid = run.child_workflow_runs.sole
    assert_equal [ "workflow", "live", "go", run.id ], [ kid.trigger_kind, kid.mode, kid.parent_step_key, kid.parent_workflow_run_id ]
    assert_equal [ "child got main-2 from Sam", "succeeded: child got main-2 from Sam" ], said
  end

  test "a call to a workflow that isn't there, or that fails, fails the step" do
    run = drain(start_workflow(workflow("triggers" => MANUAL, "steps" => [ { "key" => "go", "type" => "call", "workflow" => "nowhere" } ])))
    assert_equal [ "failed", %(ArgumentError: no workflow with key "nowhere") ], [ run.status, step_of(run, "go").error ]

    child = workflow({ "triggers" => MANUAL, "steps" => [ say("inner", "fail") ] }, key: "child-#{SecureRandom.hex(3)}")
    run = drain(start_workflow(workflow("triggers" => MANUAL, "steps" => [ { "key" => "go", "type" => "call", "workflow" => child.key } ])))
    assert_equal [ "failed", "error", "failed" ], [ run.status, step_of(run, "go").status, step_of(run, "go").output["result"] ]
  end

  # A `call` step creates its child inside the parent's lock. A worker that
  # ran the child's AdvanceJob before that commit would find no run.
  test "a run started inside a transaction is advanced only after the commit" do
    wf = workflow("triggers" => MANUAL, "steps" => [ { "key" => "ok", "type" => "approval" } ])
    ActiveRecord::Base.transaction(requires_new: true) do
      start_workflow(wf)
      assert_no_enqueued_jobs only: Harbor::Workflows::AdvanceJob
    end
    assert_enqueued_jobs 1, only: Harbor::Workflows::AdvanceJob
  end

  test "the host is told when a run has finished, and not while it is parked" do
    finished = []
    Harbor.config.workflow_run_finished = ->(run) { finished << [ run.id, run.status ] }
    run = start_workflow(workflow("triggers" => MANUAL, "steps" => [ { "key" => "ok", "type" => "approval" } ]))
    drain(run)
    assert_empty finished
    Control.decide!(run, step_run_id: step_of(run, "ok").id, approved: false)
    drain(run)
    Harbor::Workflows::AdvanceJob.perform_now(run.id)
    assert_equal [ [ run.id, "succeeded" ] ], finished
  end

  # --- what a run is about ---

  test "a run is about nothing unless it is started with a subject, or the host derives one" do
    wf = workflow("triggers" => MANUAL, "steps" => [ { "key" => "ok", "type" => "approval" } ])
    plain = start_workflow(wf)
    assert_equal [ nil, nil, nil, nil ], [ plain.github_repo, plain.pr_number, plain.issue_number, plain.subject_label ]
    assert start_workflow(wf), "runs about nothing don't hold each other up"

    about = start_workflow(wf, subject: { repo: "acme/app", pr_number: 12 })
    assert_equal [ "acme/app", 12, "PR #12", 12 ], [ about.github_repo, about.pr_number, about.subject_label, about.context.dig("run", "pr") ]
    assert_nil start_workflow(wf, subject: { repo: "acme/app", pr_number: 12 }), "one active run per workflow per subject"
    assert start_workflow(wf, subject: { repo: "acme/app", pr_number: 13 })

    Harbor.config.workflow_subject = ->(trigger, input) { { repo: trigger["repo"], issue_number: input["issue"] } }
    derived = Harbor::Workflows.start!(wf, trigger: { "kind" => "manual", "repo" => "acme/docs" }, kind: "manual", input: { "issue" => 7 })
    assert_equal [ "acme/docs", 7, "issue #7" ], [ derived.github_repo, derived.issue_number, derived.subject_label ]
  end

  test "a workflow with no saved version doesn't start, and one delivery starts a workflow once" do
    assert_nil start_workflow(Harbor::Workflow.create!(key: "empty", name: "Empty"))
    wf = workflow("triggers" => MANUAL, "steps" => [ { "key" => "ok", "type" => "approval" } ])
    assert start_workflow(wf, dedupe_key: "delivery-1")
    assert_nil start_workflow(wf, dedupe_key: "delivery-1")
  end

  test "run again starts from the top with the same trigger and input" do
    Harbor::Workflows.register_trigger "ticket", label: "Ticket", matches: ->(*) { true }
    wf = workflow("triggers" => [ { "kind" => "ticket" } ], "steps" => [ say("hello", "{{input.branch}} for {{trigger.queue}}") ])
    first = drain(Harbor::Workflows.start!(wf, trigger: { "kind" => "ticket", "queue" => "support" }, kind: "ticket", input: { "branch" => "main" }))
    again = drain(Control.rerun!(first))
    assert_equal [ "main for support", "main for support" ], said
    assert_equal "manual", again.trigger_kind, "a kind deliveries start is started by hand the second time"
    assert_equal "manual", Control.rerun!(drain(start_workflow(wf))).trigger_kind
  end

  # --- waits ---

  test "a parked step past its expiry finishes as timed out" do
    waiter = Module.new do
      def self.start(engine, _step, step_run, _input)
        step_run.waits.create!(workflow_run: engine.run, matcher: { "event" => "reply" }, expires_at: 1.hour.from_now)
        step_run.update!(status: "waiting")
        :blocked
      end
    end
    Harbor::Workflows.register_step "pause", label: "Pause", runner: waiter
    run = drain(start_workflow(workflow("triggers" => MANUAL, "steps" => [ { "key" => "rest", "type" => "pause" }, say("after", "{{steps.rest.timed_out}}") ])))
    assert_equal [ "waiting", 1 ], [ run.status, run.waits.count ]

    Harbor::Workflows.sweep_waits!(30.minutes.from_now)
    assert_equal "waiting", drain(run).status
    Harbor::Workflows.sweep_waits!(2.hours.from_now)
    run = drain(run)
    assert_equal [ "succeeded", true, 0, [ "true" ] ], [ run.status, step_of(run, "rest").output["timed_out"], run.waits.count, said ]
  end
end
