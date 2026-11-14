module Harbor
  module Automations
    # Starts each enabled scheduled automation whose cron came due since it
    # last fired. Call it every minute (Harbor::Automations::TickJob does).
    # It is not a run itself; every firing is one (Dispatch).
    #
    # The claim is a compare-and-set on last_scheduled_at in the database, so
    # two ticks running at once (a slow minute, an overlapping restart) can't
    # fire the same automation twice, and after an outage an automation fires
    # once for the latest time it missed, not once per missed minute. A
    # dispatch that raises (the queue is down, a job class that won't
    # enqueue) hands the occurrence back, so the next tick tries it again
    # instead of losing it until the next cron.
    module Tick
      module_function

      def call(now = Time.current)
        Harbor.automation_class.enabled.scheduled.find_each do |automation|
          due = automation.due_at(now)
          next unless due
          previous = automation.last_scheduled_at
          claimed = Harbor.automation_class.where(id: automation.id)
                          .where("last_scheduled_at IS NULL OR last_scheduled_at < ?", due)
                          .update_all(last_scheduled_at: due)
          next unless claimed == 1

          begin
            result = Dispatch.call(automation, trigger_source: "cron", trigger_ref: "cron:#{due.iso8601}",
                                               idempotency_key: "automation-#{automation.id}-#{due.to_i}")
          rescue
            Harbor.automation_class.where(id: automation.id, last_scheduled_at: due).update_all(last_scheduled_at: previous)
            raise
          end
          Rails.logger.info("[automations] tick #{automation.key} (#{automation.cron}): " \
                            "#{result.note || "run ##{result.run&.id}"}")
        rescue => e
          Rails.logger.error("[automations] tick #{automation.key} failed, will retry next tick: #{e.class}: #{e.message}")
        end
      end
    end
  end
end
