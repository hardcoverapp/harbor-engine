module Harbor
  module Automations
    # Runs an agent automation as an agent session, for a site that hasn't
    # said otherwise (`config.automation_agent_run`). The run is made when
    # the automation fires, so "Run now" can land on it; this job starts its
    # session, and while the agent or every runtime is full, or no model is
    # available, leaves the run waiting and looks again shortly. Harbor
    # watches and finishes the session from there.
    class AgentRunJob < ActiveJob::Base
      queue_as :default

      # What the run is filed under. Not a task type anyone routes: the agent
      # is the automation's own.
      TASK_TYPE = "automation".freeze
      RETRY_AFTER = 30.seconds

      # Makes the queued run and enqueues the job. Returns nil when
      # `idempotency_key` already has a run.
      def self.dispatch!(automation, trigger_source:, triggered_by_user: nil, trigger_ref: nil, context: {}, idempotency_key: nil)
        context = context.to_h.transform_keys(&:to_s)
        run = Harbor.run_class.claim!(
          idempotency_key:, status: "queued", automation_id: automation.id, agent_key: automation.agent_key,
          skill: automation.key, task_type: TASK_TYPE, acting_as: automation.run_as.presence,
          trigger: automation.trigger_kind, trigger_source:, trigger_ref:, triggered_by_user_id: triggered_by_user.try(:id),
          subject_type: context["subject_type"], subject_id: context["subject_id"],
          input: context.merge("automation_id" => automation.id))
        return nil if run.nil?

        begin
          perform_later(run.id)
        rescue => e
          # A queued run with no job behind it would count as in flight and
          # block every later firing. It stays as the record of the failure,
          # finished, and gives up its idempotency key for the retry.
          run.update!(idempotency_key: nil)
          run.finish!(status: "error", error: "could not enqueue #{name}: #{e.class}: #{e.message}")
          raise
        end
        run
      end

      def perform(run_id)
        run = Harbor.run_class.find_by(id: run_id)
        # Stopped while it waited, or started by an earlier try of this job.
        return if run.nil? || run.finished? || Harbor::AgentSession.session?(run)

        automation = Harbor.automation_class.find_by(id: run.automation_id)
        return run.finish!(status: "skipped", error: "The automation this run was for no longer exists.") if automation.nil?
        agent = automation.agent
        return run.finish!(status: "error", error: "#{automation.name} has no agent that is switched on.") unless agent&.enabled?

        Session.start!(run:, automation:, agent:, prompt: Template.render(automation.prompt, run.input).presence,
                       slash_command: Template.render(automation.slash_command, run.input).presence)
        self.class.set(wait: RETRY_AFTER).perform_later(run_id) if run.reload.pending?
      rescue Session::Refused => e
        run.finish!(status: "error", error: e.message)
      end
    end
  end
end
