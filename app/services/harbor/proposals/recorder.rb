module Harbor
  module Proposals
    # Turns a drafting run's answer into proposals. The host's drafter
    # (`config.proposal_drafter`) runs an agent over a batch of one scorer's
    # failures on one agent; when that run has finished ok, its final text
    # comes here:
    #
    #   Harbor::Proposals::Recorder.call(run:, scorer:, agent:, results:, text:)
    #
    # Each entry of the answer (Verdict) becomes a proposal: an agent's
    # prompt or document with the text as it is now and as proposed, or a
    # host's target through its `build` (Harbor::Proposals.register_target).
    # An entry that changes nothing is dropped. The failures the run was
    # shown are marked reviewed, by the first proposal when there is one, and
    # the run's output names the proposals and the pattern it found.
    #
    # With no answer to read, nothing is recorded: the run is finished as an
    # error and the failures are released for the next check. A drafter whose
    # run didn't finish ok releases them itself (`release!`).
    module Recorder
      # What a host target's `build` is given beside the entry.
      Draft = Struct.new(:run, :scorer, :agent, :results, :pattern, :evidence, keyword_init: true)

      NO_ANSWER = "The run finished without a proposals block — nothing was recorded; these failures stay unreviewed.".freeze

      module_function

      # Returns the proposals made, or nil when the answer couldn't be read.
      def call(run:, scorer:, agent:, results:, text:)
        verdict = Verdict.parse(text)
        if verdict.nil?
          release!(results)
          run.finish!(status: "error", output: run.output, error: NO_ANSWER)
          return nil
        end

        evidence = { "run_ids" => results.map(&:run_id).uniq, "scorer_result_ids" => results.map(&:id) }
        draft = Draft.new(run:, scorer:, agent:, results:, pattern: verdict.pattern, evidence:)
        created = verdict.proposals.filter_map { |entry| build(entry, draft) }
        # Only the failures this run was shown are marked reviewed.
        Harbor::ScorerResult.where(id: results.map(&:id)).update_all(reviewed_at: Time.current, claimed_at: nil, proposal_id: created.first&.id)
        run.update!(output: run.output.merge("proposals" => created.map(&:id), "pattern" => verdict.pattern))
        created
      end

      # The drafting run didn't answer: give the batch back to the next check.
      def release!(results)
        Harbor::ScorerResult.where(id: results.map(&:id)).update_all(claimed_at: nil)
      end

      def build(entry, draft)
        agent = draft.agent
        summary = entry["summary"].to_s.strip.presence || "Proposed change for #{agent.key}"
        common = { scorer: draft.scorer, agent_key: agent.key, run: draft.run, target_kind: entry["target"], summary: }
        case entry["target"]
        when "agent_prompt"
          after = entry["after"].to_s
          return nil if after.strip.blank? || after == agent.system_prompt.to_s
          Harbor.proposal_class.create!(**common, before: agent.system_prompt.to_s, after:,
                                        regressions_addressed: draft.pattern, evidence: draft.evidence)
        when "agent_document"
          path = entry["path"].to_s.strip
          after = entry["after"].to_s
          return nil if path.blank? || after.strip.blank?
          before = agent.agent_documents.find_by(path:)&.body.to_s
          return nil if after == before
          Harbor.proposal_class.create!(**common, document_path: path, before:, after:,
                                        regressions_addressed: draft.pattern, evidence: draft.evidence)
        else
          attributes = Harbor::Proposals.target(entry["target"])&.build&.call(entry, draft)
          return nil if attributes.nil?
          Harbor.proposal_class.create!(**{ regressions_addressed: draft.pattern, evidence: draft.evidence }.merge(common, attributes.to_h.symbolize_keys))
        end
      end
    end
  end
end
