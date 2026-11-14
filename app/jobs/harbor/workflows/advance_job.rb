module Harbor
  module Workflows
    # The only thing that moves a workflow run forward (Engine). Idempotent:
    # the engine locks the run and replays, so a double enqueue is harmless.
    # When an advance finishes the run, the host is told
    # (`config.workflow_run_finished`).
    class AdvanceJob < ActiveJob::Base
      queue_as :default

      # Callers enqueue this inside a run's lock: a `call` step creates its
      # child run in the parent's transaction. Enqueued straight away, a
      # worker could pick the job up before that commit, find no run, and
      # leave the child queued forever. Wait for the commit.
      self.enqueue_after_transaction_commit = true

      def perform(workflow_run_id)
        finished = Engine.advance!(workflow_run_id)
        Harbor.config.workflow_run_finished&.call(finished) if finished
      rescue => e
        Rails.logger.error("[harbor] advancing workflow run #{workflow_run_id} failed: #{e.class}: #{e.message}")
        Harbor.workflow_run_class.find_by(id: workflow_run_id)&.update(error: "#{e.class}: #{e.message}".truncate(2000))
        raise
      end
    end
  end
end
