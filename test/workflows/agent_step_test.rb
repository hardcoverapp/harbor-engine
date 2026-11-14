require "test_helper"

# Harbor's own agent and verifier steps: the step's agent runs as an agent
# session on the stand-in Orca, a tracked Run, and the session's result comes
# back to the step.
class HarborWorkflowsAgentStepTest < ActionDispatch::IntegrationTest
  include HarborAgentSessions
  include HarborWorkflows

  AgentStepJob = Harbor::Workflows::AgentStepJob

  def agent_workflow(**step)
    workflow("triggers" => [ { "kind" => "manual" } ],
             "steps" => [ { "key" => "work", "type" => "agent", "agent" => "writer", "prompt" => "Tidy {{input.branch}}" }.merge(step.stringify_keys) ],
             "finally" => [ { "key" => "done", "type" => "action", "action" => "note", "message" => "{{steps.work.text}}" } ])
  end

  # The step's job, and the session checks it queues, run once.
  def start_sessions = perform_enqueued_jobs(only: AgentStepJob)

  # The session's command reports its result and exits, as a runner would.
  def session_ends(run, text, exit_status: 0)
    post_output(run, ndjson({ "type" => "system", "subtype" => "init", "session_id" => "sess-#{run.id}" },
                            { "type" => "result", "subtype" => "success", "is_error" => false, "result" => text,
                              "session_id" => "sess-#{run.id}", "total_cost_usd" => 0.25 }))
    post_result(run, exit_status)
    run.reload
  end

  test "an agent step is a tracked Run that runs as a session, and its result moves the workflow on" do
    workflow_run = drain(start_workflow(agent_workflow, input: { "branch" => "main" }))
    run = workflow_run.runs.sole
    assert_equal [ "queued", "writer", "workflow", "workflow", "work", "wf-step-#{step_of(workflow_run, 'work').id}" ],
                 [ run.status, run.agent_key, run.task_type, run.trigger_source, run.workflow_step_key, run.idempotency_key ]
    assert_equal "workflow.#{workflow_run.workflow.key}.work", run.skill
    assert_equal "running", workflow_run.status

    start_sessions
    run.reload
    assert_equal "running", run.status
    assert Harbor::AgentSession.session?(run)
    assert_equal "Tidy main", Harbor::AgentSession.bundle_file(run, "prompt")
    assert_equal [ "worktree create", "terminal create" ], @orca.commands.first(2)

    session_ends(run, "Tidied.\n```json\n{\"files\": 3}\n```")
    workflow_run = drain(workflow_run)
    assert_equal "succeeded", workflow_run.status
    out = step_of(workflow_run, "work").output
    assert_equal [ run.id, 0, 0.25, 3 ], out.values_at("run_id", "exit_code", "cost_usd", "files")
    assert_match "Tidied.", out["text"]
    assert_equal 0.25, workflow_run.cost_usd
  end

  test "a step that returns values, and a verifier, are told how to in the system prompt" do
    drain(start_workflow(agent_workflow(outputs: %w[branch files])))
    start_sessions
    system = Harbor::AgentSession.bundle_file(Harbor::Run.last, "system")
    assert_match "fenced ```json block containing these keys: branch, files", system

    verifier = workflow("triggers" => [ { "kind" => "manual" } ],
                        "steps" => [ { "key" => "check", "type" => "verifier", "agent" => "writer", "slash_command" => "/check:all main", "verdicts" => %w[pass fail] } ])
    workflow_run = drain(start_workflow(verifier))
    start_sessions
    run = workflow_run.runs.sole
    assert_match "{\"verdict\": one of pass | fail", Harbor::AgentSession.bundle_file(run, "system")
    assert_equal "main", Harbor::AgentSession.bundle_file(run, "arguments").strip, "a slash command's arguments go to the runner"

    session_ends(run, "```json\n{\"verdict\": \"fail\", \"feedback\": \"two tests fail\"}\n```")
    assert_equal [ "fail", "two tests fail" ], step_of(drain(workflow_run), "check").output.values_at("verdict", "feedback")
  end

  test "an agent for a task type follows who the task is given to" do
    Harbor::TaskTypes.reset!
    Harbor::TaskTypes.declare "tidy"
    Harbor::TaskAssignment.create!(task_type: "tidy", agent_key: "writer")
    workflow_run = drain(start_workflow(agent_workflow(agent: "task:tidy")))
    assert_equal "writer", workflow_run.runs.sole.agent_key
  ensure
    Harbor::TaskTypes.reset!
  end

  test "a step naming no enabled agent fails with the reason and starts nothing" do
    workflow_run = drain(start_workflow(agent_workflow(agent: "nobody")))
    assert_equal [ "failed", %(ArgumentError: no enabled agent with key "nobody") ], [ workflow_run.status, step_of(workflow_run, "work").error ]
    assert_empty workflow_run.runs

    @agent.update!(enabled: false)
    assert_match "no enabled agent", step_of(drain(start_workflow(agent_workflow)), "work").error
  end

  test "a session that fails fails the step with the run's error" do
    workflow_run = drain(start_workflow(agent_workflow))
    start_sessions
    run = workflow_run.runs.sole
    post_output(run, "fatal: not a git repository\n")
    post_result(run, 128)
    workflow_run = drain(workflow_run)
    assert_equal [ "failed", "error" ], [ workflow_run.status, step_of(workflow_run, "work").status ]
    assert_equal run.reload.error, step_of(workflow_run, "work").error
    assert_match "not a git repository", step_of(workflow_run, "work").error
    assert_equal "ok", step_of(workflow_run, "done").status, "cleanup still ran"
  end

  test "while the agent is full the run waits and the job comes back; then it starts" do
    @agent.update!(max_agents: 1)
    Harbor::Slots.acquire(@agent, "someone-else", ttl: 600)
    Harbor::Setting.set!(:workflow_agent_retry_seconds, 45)
    workflow_run = drain(start_workflow(agent_workflow))
    run = workflow_run.runs.sole

    assert_enqueued_with(job: AgentStepJob, args: [ step_of(workflow_run, "work").id, run.id ]) { AgentStepJob.perform_now(step_of(workflow_run, "work").id, run.id) }
    again = enqueued_jobs.select { |job| job["job_class"] == AgentStepJob.name }.last
    assert_in_delta 45.seconds.from_now.to_f, Time.iso8601(again["scheduled_at"]).to_f, 5
    assert_equal [ "queued", "running" ], [ run.reload.status, step_of(workflow_run, "work").status ]
    assert_empty @orca.commands

    HARBOR_TEST_REDIS.with { |r| r.call("KEYS", "harbor:test:slots:*").each { |k| r.call("DEL", k) } }
    AgentStepJob.perform_now(step_of(workflow_run, "work").id, run.id)
    assert_equal "running", run.reload.status
  end

  test "a session that can't be started finishes the Run as an error, which fails the step" do
    workflow_run = drain(start_workflow(agent_workflow(slash_command: "../../etc/passwd now", prompt: nil)))
    start_sessions
    run = workflow_run.runs.sole
    assert_equal "error", run.reload.status
    assert_match "ArgumentError", run.error
    assert_equal "failed", drain(workflow_run).status
  end

  test "the job does nothing for a Run that already started, or whose step moved on" do
    workflow_run = drain(start_workflow(agent_workflow))
    start_sessions
    run = workflow_run.runs.sole
    terminals = @orca.terminal_commands.size
    AgentStepJob.perform_now(step_of(workflow_run, "work").id, run.id)
    assert_equal terminals, @orca.terminal_commands.size

    other = drain(start_workflow(agent_workflow))
    Harbor::Workflows::Control.cancel!(other)
    AgentStepJob.perform_now(step_of(other, "work").id, other.runs.sole.id)
    assert_equal "canceled", other.runs.sole.status
    assert_equal terminals, @orca.terminal_commands.size
  end

  test "canceling a workflow run stops its agent's session" do
    workflow_run = drain(start_workflow(agent_workflow))
    start_sessions
    run = workflow_run.runs.sole
    Harbor::Workflows::Control.cancel!(workflow_run)
    assert_equal "canceled", run.reload.status
    assert_includes @orca.commands, "terminal close"
    workflow_run = drain(workflow_run)
    assert_equal [ "canceled", "canceled" ], [ workflow_run.status, step_of(workflow_run, "work").status ]
  end

  test "session: continue picks up the session of the step's previous pass" do
    wf = workflow("triggers" => [ { "kind" => "manual" } ],
                  "steps" => [ { "key" => "rounds", "type" => "loop", "max_iterations" => 2,
                                 "steps" => [ { "key" => "work", "type" => "agent", "agent" => "writer", "prompt" => "pass {{loop.rounds.iteration}}", "session" => "continue" } ] } ])
    workflow_run = drain(start_workflow(wf))
    start_sessions
    first = workflow_run.runs.sole
    session_ends(first, "one")
    workflow_run = drain(workflow_run)
    start_sessions
    second = workflow_run.runs.order(:id).last
    assert_equal "sess-#{first.id}", second.reload.runner_state["resume_session_id"]
  end
end
