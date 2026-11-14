module Harbor
  module Proposals
    # The check: for each enabled scorer with self-improvement on, group its
    # unreviewed failures by the agent that produced them, and hand each group
    # that has grown enough, or waited long enough, to the host's drafter
    # (`config.proposal_drafter`). A check started by a person takes every
    # group with one failure.
    #
    # It runs as a run made beforehand (by a schedule of the host's, or by
    # "Run the check now" on the Proposals page), with that run's live log.
    class CheckJob < ActiveJob::Base
      queue_as :default

      SKILL = "self-improvement-check".freeze
      # Exactly what one drafting run is shown, so nothing is marked reviewed
      # unseen.
      MAX_RESULTS_PER_GROUP = Harbor::Proposals::BATCH
      NO_DRAFTER = "No drafter is configured, so no proposal can be drafted: this site has to set " \
                   "Harbor.config.proposal_drafter (see Proposals in Harbor's README).".freeze

      def perform(run_id)
        run = Harbor.run_class.find(run_id)
        return if run.finished?
        run.start!
        log = Harbor::LiveLog.open(run.live_log_path)
        drafter = Harbor.config.proposal_drafter
        if drafter.nil?
          log&.call("[self-improvement] #{NO_DRAFTER}")
          return run.finish!(status: "error", error: NO_DRAFTER)
        end
        scorers = Harbor.scorer_class.enabled.where(self_improvement: true).ordered.to_a
        if scorers.empty?
          log&.call("[self-improvement] no enabled scorer has self-improvement on — nothing to check")
          return run.finish!(status: "skipped", error: "No enabled scorer has self-improvement switched on (see #{scorers_page}).")
        end

        groups = 0
        dispatched = []
        scorers.each do |scorer|
          failures = scorer.scorer_results.failed.unreviewed.includes(:run).to_a
          failures.group_by { |r| r.run&.agent_key }.each do |agent_key, rows|
            next if agent_key.blank?
            groups += 1
            oldest = rows.filter_map(&:scored_at).min
            due = rows.size >= scorer.improvement_min_failures ||
                  (oldest && oldest <= scorer.improvement_max_age_days.days.ago) ||
                  run.trigger_manual?
            unless due
              log&.call("[self-improvement] #{scorer.name} / #{agent_key}: #{rows.size} failure(s), oldest #{oldest ? time_ago(oldest) : '—'} — " \
                        "waiting for #{scorer.improvement_min_failures} or #{scorer.improvement_max_age_days} days")
              next
            end
            wanted = rows.sort_by { |r| r.scored_at || r.created_at }.map(&:id).first(MAX_RESULTS_PER_GROUP)
            # Claim the batch now, atomically: a second check (by hand or
            # scheduled, even one racing this one) gets only the rows this
            # one didn't, and nothing is proposed twice.
            ids = Harbor::ScorerResult.claim_for_review!(wanted)
            if ids.empty?
              log&.call("[self-improvement] #{scorer.name} / #{agent_key}: another check already took these #{wanted.size} failure(s)")
              next
            end
            drafter.call(scorer:, agent_key:, result_ids: ids, check_run: run)
            dispatched << { scorer: scorer.name, agent: agent_key, failures: ids.size }
            log&.call("[self-improvement] #{scorer.name} / #{agent_key}: #{ids.size} failure(s) → proposing")
          end
        end
        run.finish!(status: "ok", output: { groups:, dispatched: })
      rescue => e
        log&.call("[self-improvement] ERROR: #{e.class}: #{e.message}")
        run&.finish!(status: "error", error: "#{e.class}: #{e.message}")
      ensure
        Harbor::LiveLog.close(log) if log
      end

      private

      def time_ago(time) = "#{((Time.current - time) / 86_400).floor}d ago"

      def scorers_page = Harbor::Engine.routes.url_helpers.scorers_path
    end
  end
end
