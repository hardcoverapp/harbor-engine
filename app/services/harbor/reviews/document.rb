module Harbor
  module Reviews
    # A round as one document: what a site's review steps pass between them,
    # what the round's page shows and its .json address serves. Built from
    # the rows every time, never stored as the source of truth. Its `schema`
    # is the site's name for the format (`config.review_document_schema`).
    module Document
      def self.schema = Harbor.config.review_document_schema

      module_function

      def for(round)
        checks = round.check_runs.includes(:review_rule, :reused_from).to_a
        {
          "schema" => schema, "round_id" => round.id, "repo" => round.repo, "pr" => round.pr_number, "head_sha" => round.head_sha,
          "round" => round.round, "phase" => round.phase, "dry_run" => round.dry_run,
          "trigger_source" => round.trigger_source,
          "progress" => Progress.for(round, checks),
          "risks" => round.risks, "gaps" => round.gaps,
          "checks" => checks.map { |c| check_entry(c) },
          "gate" => round.gate.presence || { "result" => "pending", "blocking_failures" => [] },
          "signoffs" => round.signoffs,
          "review" => round.review.presence || { "status" => "pending" },
          "input" => round.input.except("workspace_path", "workspace_owned"),
          "cost" => cost(round, checks)
        }.compact
      end

      # "$1.84 · 6 min · 4 checks (2 reused)": what the round has cost so far.
      # The runs counted are each check's, and the one a site names in the
      # round's input as `code_review_run_id`.
      def cost(round, checks)
        run_ids = checks.filter_map(&:run_id) + [ round.input["code_review_run_id"] ].compact
        usd = Harbor.run_class.where(id: run_ids).sum("COALESCE(cost_usd_actual, cost_usd_estimate, 0)").to_f
        minutes = ((round.finished_at || Time.current) - round.created_at) / 60.0
        reused = checks.count { |c| c.status == "reused" }
        "$#{format('%.2f', usd)} · #{minutes.round} min · #{checks.size} #{'check'.pluralize(checks.size)}#{" (#{reused} reused)" if reused.positive?}"
      end

      def check_entry(c)
        d = c.definition
        {
          "key" => c.check_key, "name" => c.review_rule.name, "version" => c.check_version,
          "mitigates" => d["mitigates"], "kind" => d["kind"], "gate" => c.gate, "stage" => c.stage, "mode" => c.mode,
          "status" => c.status,
          "progress" => ({ "done" => c.progress_done, "total" => c.progress_total, "note" => c.progress_note } if c.progress_total),
          "summary" => c.summary, "outputs" => c.outputs, "routed" => c.routed, "artifacts" => c.artifacts,
          "run_id" => c.run_id,
          "reused_from" => (c.reused_from && { "head_sha" => c.reused_from.review_round.head_sha, "run_id" => c.reused_from.run_id }),
          "started_at" => c.started_at&.iso8601, "finished_at" => c.finished_at&.iso8601
        }.compact
      end

      # Where the round is, in a line: "Evidence 2 of 5 · 40%", "Approved".
      def title(doc)
        p = doc["progress"]
        case doc["phase"]
        when "triage"   then "Planning evidence"
        when "evidence" then p["total"].zero? ? "No evidence needed" : "Evidence #{p['done']} of #{p['total']} · #{p['percent']}%#{eta(p)}"
        when "review"   then "Evidence passed · reviewing the code"
        when "cancelled" then "Superseded#{" by #{doc.dig('input', 'superseded_by')}" if doc.dig('input', 'superseded_by')}"
        else final_title(doc)
        end
      end

      # How a round that has finished its evidence and review came out.
      def final_title(doc)
        waiting = Array(doc["signoffs"]).select { |s| s["status"] == "waiting" && s["mode"] != "shadow" }
        verdict = doc.dig("review", "verdict")
        if doc.dig("gate", "result") == "failed"
          "Evidence failed: #{names(doc, doc.dig('gate', 'blocking_failures')).join(', ')}"
        elsif verdict == "REQUEST_CHANGES"
          "Changes requested: #{count(doc, 'blocking')} blocking"
        elsif waiting.any?
          "Waiting on #{waiting.flat_map { |s| s['who'] }.uniq.join(', ')}: #{waiting.map { |s| s['name'] }.join(', ')}"
        elsif verdict == "APPROVE"
          "Approved"
        else
          "Needs a person"
        end
      end

      def names(doc, keys)
        Array(keys).map { |k| doc["checks"].find { |c| c["key"] == k }&.dig("name") || k }
      end

      def count(doc, severity) = Array(doc.dig("review", "findings")).count { |f| f["severity"] == severity }

      def eta(p)
        s = p["eta_seconds"] or return ""
        " · about #{(s / 60.0).ceil} min left"
      end
    end
  end
end
