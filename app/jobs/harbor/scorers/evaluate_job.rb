module Harbor
  module Scorers
    # Judge one run with one scorer. The judge is recorded as a child run of
    # the run it grades: cost, model, transcript and events live there like
    # any run's. The verdict lands on a scorer result; re-scoring replaces it.
    #
    # Running a model over the transcript is the host's (`config.scorer_judge`,
    # see Judgement): Harbor makes the judge run and the result, asks the
    # host's judge, reads the verdict from its answer, and records how it
    # went. With no judge configured the judgement ends as an error that says
    # so.
    class EvaluateJob < ActiveJob::Base
      queue_as :default

      SKILL = Harbor::Scorer::JUDGE_SKILL
      # When the judge says it is busy, try again later rather than losing
      # the sampling decision; the claim stays queued.
      BUSY_RETRY_AFTER = 2.minutes
      BUSY_RETRIES = 10
      NO_JUDGE = "No judge is configured, so nothing can be scored: this site has to set Harbor.config.scorer_judge " \
                 "(see Scorers in Harbor's README).".freeze

      def perform(scorer_id:, run_id:, trigger_source: "watcher", triggered_by_user_id: nil, busy_retries: 0)
        scorer = Harbor.scorer_class.find_by(id: scorer_id)
        run    = Harbor.run_class.find_by(id: run_id)
        return if scorer.nil? || run.nil?

        result = Harbor::ScorerResult.find_or_initialize_by(scorer:, run:)
        result.update!(status: "queued", error: nil)
        judge = Harbor.run_class.create!(
          parent_run_id: run.id, skill: SKILL, trigger: "scorer:#{scorer.id}", trigger_source:, triggered_by_user_id:,
          subject_type: Harbor.run_class.name, subject_id: run.id,
          input: { scorer_id: scorer.id, scorer: scorer.name, run_id: run.id },
        )
        result.update!(judge_run: judge)
        judgement = Judgement.new(scorer:, run:, judge:, result:, attempt: busy_retries)

        hook = Harbor.config.scorer_judge
        return judgement.fail!(NO_JUDGE) if hook.nil?

        text = hook.call(judgement)
        judgement.answer!(text) if text.is_a?(String) && !judgement.settled?
      rescue Judgement::Busy => e
        retry_later!(judgement, scorer_id:, run_id:, trigger_source:, triggered_by_user_id:, busy_retries:, reason: e.message)
      rescue Harbor::ModelAlias::Unavailable => e
        (judgement || Judgement.new(scorer:, run:, judge:, result:)).fail!(e.message, status: "skipped")
      rescue => e
        Rails.logger.error("[scorers] evaluate failed: #{e.class}: #{e.message}")
        (judgement || Judgement.new(scorer:, run:, judge:, result:)).fail!("#{e.class}: #{e.message}") if judge
      ensure
        judgement&.close_log
      end

      private

      # The judge held this one as long as it would; re-enqueue instead of
      # recording a failure. The claim stays queued (touched, so it isn't
      # stale), the attempted judge run is closed out as skipped with the
      # reason, and the retries are bounded.
      def retry_later!(judgement, scorer_id:, run_id:, trigger_source:, triggered_by_user_id:, busy_retries:, reason:)
        if busy_retries >= BUSY_RETRIES
          return judgement.fail!("the judge stayed busy through #{BUSY_RETRIES} retries: #{reason.to_s.strip.last(300)}")
        end
        judgement.judge.finish!(status: "skipped", error: "judge busy — retrying in #{BUSY_RETRY_AFTER.inspect} (#{busy_retries + 1}/#{BUSY_RETRIES})")
        judgement.result.update!(status: "queued", error: nil, judge_run: nil)
        self.class.set(wait: BUSY_RETRY_AFTER).perform_later(scorer_id:, run_id:, trigger_source:, triggered_by_user_id:,
                                                             busy_retries: busy_retries + 1)
        nil
      end
    end
  end
end
