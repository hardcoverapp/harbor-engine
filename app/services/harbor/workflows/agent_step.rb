module Harbor
  module Workflows
    # Harbor's own agent and verifier steps: the step's agent runs as an agent
    # session (Harbor::AgentSession), a tracked Run carrying the workflow run
    # and the step's key. When the Run finishes, however it finishes, the
    # result goes back to the step (StepCompletion) and the workflow moves on.
    #
    # `agent` is an agent's key, or "task:<task type>" for whoever that task
    # type is given to, so a workflow follows reassignments.
    #
    # A host that runs agents another way registers its own runner for the
    # "agent" and "verifier" types; its Runs come back the same way as long
    # as they carry `workflow_run_id` and are the step run's `run`.
    module AgentStep
      TASK_TYPE = "workflow".freeze
      DEFAULT_TIMEOUT_MINUTES = 60

      module_function

      # Makes the step's Run and queues the job that starts its session.
      # Called inside the engine's lock; the job waits for the commit.
      def dispatch!(step_run)
        input = step_run.input
        workflow_run = step_run.workflow_run
        agent = agent_for(input["agent"])
        run = Harbor.run_class.claim!(
          idempotency_key: idempotency_key_for(step_run),
          agent_key: agent.key, status: "queued",
          skill: "workflow.#{workflow_run.workflow.key}.#{step_run.step_key}", task_type: TASK_TYPE,
          trigger: "workflow", trigger_source: "workflow", trigger_ref: "workflow:#{workflow_run.id}:#{step_run.step_key}",
          workflow_run_id: workflow_run.id, workflow_step_key: step_run.step_key,
          input: { "workflow_run_id" => workflow_run.id, "step" => step_run.step_key, "agent" => input["agent"] }
        )
        raise ArgumentError, "the step's Run already exists" if run.nil?
        step_run.update!(run:)
        AgentStepJob.perform_later(step_run.id, run.id)
        run
      end

      def idempotency_key_for(step_run) = "wf-step-#{step_run.id}"

      # The enabled agent a step names. Raises when there is none, which
      # fails the step with the reason.
      def agent_for(key)
        key = key.to_s
        agent = key.start_with?("task:") ? Harbor.task_assignment_class.agent_for(key.delete_prefix("task:")) : Harbor.agent_class.find_by(key:)
        return agent if agent&.enabled?
        raise ArgumentError, key.start_with?("task:") ? "no enabled agent is given #{key.delete_prefix('task:')}" : "no enabled agent with key #{key.inspect}"
      end

      # Starts the session for a step's Run. Returns the run: running, or
      # still waiting (queued / waiting_for_model) when the agent or every
      # runtime is full or no model is available, for the job to try again.
      def start!(step_run, run)
        input = step_run.input
        what = input["slash_command"].present? ? { slash_command: input["slash_command"] } : { prompt: input["prompt"].to_s }
        Harbor::AgentSession.run!(
          agent: agent_for(input["agent"]), run:, **what,
          system_prompt_extra: StepCompletion.instructions_for(input),
          timeout: (input["timeout_minutes"].presence || DEFAULT_TIMEOUT_MINUTES).to_i.minutes,
          resume_session_id: resume_session_id(step_run)
        )
      end

      # session: continue picks up the session of this step's previous pass.
      def resume_session_id(step_run)
        return nil unless step_run.input["session"] == "continue"
        Harbor.run_class.where(workflow_run_id: step_run.workflow_run_id, workflow_step_key: step_run.step_key)
              .where.not(id: step_run.run_id).where.not(session_id: nil).order(:id).last&.session_id
      end
    end
  end
end
