module Harbor
  module Workflows
    # What a person can do to a run from its page.
    module Control
      module_function

      # Stop the run: pending steps are canceled (their Runs are asked to
      # stop the way the Runs page's Stop does), waits are dropped, and the
      # `finally` steps still run so what the run set up is taken down.
      def cancel!(run, user: nil)
        run.with_lock do
          return false unless run.active?
          run.step_runs.pending.find_each do |sr|
            stop_run(sr.run, user) if sr.run&.queued_or_running_status?
            sr.waits.delete_all
            sr.finish!(status: "canceled", error: "canceled#{" by #{name_of(user)}" if user}")
          end
          run.child_workflow_runs.active.each { |child| cancel!(child, user:) }
          run.update!(outcome: "canceled", phase: run.phase == "main" ? "finally" : run.phase)
        end
        Harbor::Workflows.advance_later(run.id)
        true
      end

      # Answer an approval step.
      def decide!(run, step_run_id:, approved:, user: nil, note: nil)
        sr = run.step_runs.find(step_run_id)
        return false unless sr.step_type == "approval" && sr.pending?
        sr.finish!(status: "ok", output: sr.output.merge("decision" => approved ? "approved" : "rejected",
                                                          "by" => (name_of(user) if user), "note" => note.presence).compact)
        Harbor::Workflows.advance_later(run.id)
        true
      end

      # Start again from the top with the same trigger and input. A run of a
      # kind that deliveries start is started by hand this time.
      def rerun!(run, user: nil)
        kind = Harbor::Workflows.trigger(run.trigger_kind)&.matches ? "manual" : run.trigger_kind
        Harbor::Workflows.start!(run.workflow, trigger: run.context["trigger"].to_h, kind:, input: run.context["input"].to_h, user:)
      end

      # A step's Run that is still going: the host's way of stopping it
      # (`config.workflow_run_cancel`), else Harbor's own, as on the Runs page.
      # A failure to stop it never keeps the workflow run from being canceled.
      def stop_run(run, user)
        hook = Harbor.config.workflow_run_cancel
        return hook.call(run, user) if hook
        Harbor::RunStop.call(run, user) if Harbor::RunStop.possible?(run)
      rescue StandardError => e
        Rails.logger.error("[harbor] stopping run #{run.id} of a canceled workflow failed: #{e.class}: #{e.message}")
      end

      def name_of(user) = Harbor.config.user_label.call(user)
    end
  end
end
