module Harbor
  module Workflows
    # Starts the agent session of a workflow's agent or verifier step
    # (AgentStep). The step's Run is the record: a session that can't be
    # started finishes it as an error, which fails the step. While the agent
    # or every runtime is full, or no model is available, the Run stays
    # waiting and this comes back to try again.
    class AgentStepJob < ActiveJob::Base
      queue_as :default

      # AgentStep.dispatch! runs inside the engine's lock, which also creates
      # the step's Run. Wait for the commit, as AdvanceJob does.
      self.enqueue_after_transaction_commit = true

      def perform(step_run_id, run_id)
        run = Harbor.run_class.find_by(id: run_id) or return
        step_run = Harbor::WorkflowStepRun.find_by(id: step_run_id)
        return run.finish!(status: "skipped", error: "its workflow step is gone") if step_run.nil? && !run.finished?
        return unless step_run && run.pending? && step_run.pending? && step_run.run_id == run.id

        run = AgentStep.start!(step_run, run)
        self.class.set(wait: retry_wait).perform_later(step_run_id, run_id) if run.reload.pending?
      rescue StandardError => e
        # Nothing was started: the Run says why, and the step fails with it.
        run.finish!(status: "error", error: "#{e.class}: #{e.message}") if run && !run.reload.finished?
      end

      private
        def retry_wait = Harbor::Setting.get(:workflow_agent_retry_seconds).to_i.seconds
    end
  end
end
