module Harbor
  module Scorers
    # What the judge reads: the run it is grading, where its transcript is, the
    # scorer's question, and the exact shape of the answer Harbor parses.
    module Prompt
      module_function

      # transcript: the transcript's file name as the judge will find it, in
      # the directory the judge runs in.
      def build(scorer, run, transcript: "transcript.ndjson", site: Harbor.config.site_name)
        labels = scorer.classifications.map { |c| "- #{c['label']} (score #{c['score']})" }.join("\n")
        output = run.output.is_a?(Hash) ? run.output["text"].to_s : run.output.to_s
        <<~PROMPT
          You are a judge grading one finished agent run#{" for #{site}" if site.present?}. Read the run's transcript, decide which classification fits, and answer in the exact JSON shape at the end. You are read-only: never change any file, never run commands that alter state.

          ## The run
          - Run ##{run.id}: #{run.label}
          - Agent: #{run.agent_key || 'none'} · task type: #{run.task_type || 'none'} · skill: #{run.skill || 'none'}
          - Command: #{run.command.presence || '(prompt run)'}
          - Status: #{run.status}#{" · error: #{run.error.to_s.truncate(500)}" if run.error.present?}
          - Cost: #{run.cost_usd ? format('$%.4f', run.cost_usd) : 'unknown'} · tokens: #{run.token_summary || 'unknown'} · duration: #{run.duration_ms ? "#{(run.duration_ms / 1000.0).round}s" : 'unknown'}
          - Transcript (stream-json NDJSON, one event per line; tool calls are `assistant` events with `tool_use` blocks, results are `user` events): `#{transcript}` in the current directory — the only file here. Read it in full before deciding.
          #{"- The run's final message:\n\n```\n#{output.truncate(3000)}\n```" if output.present?}

          ## What to judge
          #{scorer.judge_instructions.strip}

          ## Classifications
          Choose exactly one label:
          #{labels}

          ## Answer
          Finish with one fenced JSON block and nothing after it:

          ```json
          {"classification": "<one of the labels above>", "score": <that label's score>, "reasoning": "<two to five sentences citing what in the transcript decided it>"}
          ```
        PROMPT
      end
    end
  end
end
