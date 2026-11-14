module Harbor
  module Automations
    # Starts an automation once, however it was triggered (the tick, a trigger
    # of the host's, "Run now"). Every path ends in a tracked run or a stated
    # reason not to:
    #
    #   job + loader/skill   the run is made here, named by the automation's
    #                        key, and the job is enqueued with its id (the
    #                        contract of Harbor::TrackedJob).
    #   job + self           the job makes its own run, so it is only asked to
    #                        start: `JobClass.automation_dispatch!(trigger_source:,
    #                        triggered_by_user_id:)`.
    #   agent                `config.automation_agent_run` when the host has
    #                        one, else a Harbor agent session
    #                        (Harbor::Automations::AgentRunJob).
    #
    # A job class may refuse a firing with a reason:
    # `JobClass.automation_skip_reason(trigger_source:)`.
    #
    # A second firing while one is still queued or running is refused unless
    # the automation allows concurrency.
    class Dispatch
      Result = Struct.new(:run, :note, :enqueued, keyword_init: true) do
        # Nothing was started: a skip the caller should surface.
        def skipped? = run.nil? && !enqueued
      end

      def self.call(automation, trigger_source:, triggered_by_user: nil, trigger_ref: nil,
                    webhook_event: nil, context: {}, idempotency_key: nil)
        new(automation).call(trigger_source:, triggered_by_user:, trigger_ref:, webhook_event:, context:, idempotency_key:)
      end

      def initialize(automation)
        @automation = automation
      end

      def call(trigger_source:, triggered_by_user:, trigger_ref:, webhook_event:, context:, idempotency_key:)
        a = @automation
        return Result.new(note: "disabled") if !a.enabled? && trigger_source != "manual"

        if !a.allow_concurrent && (existing = a.in_flight)
          return Result.new(run: existing, note: "already #{existing.status} — run ##{existing.id}")
        end

        if a.agent?
          run = agent_run(trigger_source:, triggered_by_user:, trigger_ref:, webhook_event:, context:, idempotency_key:)
          return Result.new(note: "duplicate delivery — a Run already exists for it") if run.nil?
          return Result.new(run:, enqueued: true)
        end

        klass = a.job_klass
        if klass.respond_to?(:automation_skip_reason) && (reason = klass.automation_skip_reason(trigger_source:))
          return Result.new(note: reason)
        end

        if a.job_dispatch == "self"
          klass.automation_dispatch!(trigger_source:, triggered_by_user_id: triggered_by_user.try(:id))
          return Result.new(enqueued: true, note: "queued — its Run appears in Runs momentarily")
        end

        attrs = { automation_id: a.id, trigger_source:, trigger_ref:, triggered_by_user_id: triggered_by_user.try(:id),
                  input: a.job_input.merge(context.to_h).merge(a.job_dispatch == "loader" ? { "loader" => a.key } : {}) }
        attrs[a.job_dispatch == "loader" ? :loader : :skill] = a.key
        run = Harbor.run_class.claim!(idempotency_key:, **attrs)
        return Result.new(note: "already fired for #{idempotency_key}") if run.nil?

        begin
          klass.perform_later(run.id)
        rescue => e
          # The run stays as the visible record of the failure, but gives up
          # its idempotency key so the next tick can fire the occurrence again.
          run.update!(idempotency_key: nil)
          run.finish!(status: "error", error: "could not enqueue #{klass}: #{e.class}: #{e.message}")
          raise
        end
        Result.new(run:)
      end

      private

      # The queued run of an agent automation, or nil when this firing already
      # has one.
      def agent_run(**trigger)
        hook = Harbor.config.automation_agent_run
        return hook.call(@automation, **trigger) if hook
        AgentRunJob.dispatch!(@automation, **trigger.except(:webhook_event))
      end
    end
  end
end
