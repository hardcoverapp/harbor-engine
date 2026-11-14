module Harbor
  module Scorers
    # Runs after an agent run finishes: decide which enabled scorers judge it,
    # by their filters and sample rate, and queue a judge for each. A sampling
    # decision, not a run: the judges are the runs.
    class SampleJob < ActiveJob::Base
      queue_as :default

      def perform(run_id)
        run = Harbor.run_class.find_by(id: run_id)
        return if run.nil?
        Harbor.scorer_class.enabled.ordered.each do |scorer|
          next unless scorer.applies_to?(run) && scorer.sampled?
          next if Harbor::ScorerResult.claim!(scorer:, run:).nil? # already being judged
          EvaluateJob.perform_later(scorer_id: scorer.id, run_id: run.id, trigger_source: "watcher")
          Rails.logger.info("[scorers] #{scorer.name} sampled run ##{run.id}")
        rescue => e
          # One scorer's problem (a bad row, the queue blinking) must not cost
          # the others their sample; the judge itself is the tracked run.
          Rails.logger.error("[scorers] #{scorer.name} could not sample run ##{run.id}: #{e.class}: #{e.message}")
        end
      end
    end
  end
end
