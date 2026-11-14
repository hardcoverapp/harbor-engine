module Harbor
  module Workflows
    # An agent step's Run finished: turn the Run's result into the step's
    # output and move the workflow on. Called when a Run that is a workflow
    # step finishes (Harbor::Run).
    #
    # Agents report structured output by ending their final message with a
    # fenced ```json block (the step's instructions ask for it); a verifier
    # must return a verdict from its declared list.
    module StepCompletion
      JSON_BLOCK = /```json\s*(\{.*?\})\s*```/m

      module_function

      def from_run(run)
        sr = Harbor::WorkflowStepRun.find_by(run_id: run.id)
        return unless sr&.pending?
        # A host that retries failed agent runs says so here, and the step
        # stays pending for the retry.
        return if Harbor.config.workflow_step_retry&.call(run, sr)
        text = run.output.to_h["text"].to_s
        parsed = parse_json(text)
        output = { "run_id" => run.id, "text" => text.last(1500), "exit_code" => run.output.to_h["exit_code"],
                   "cost_usd" => run.cost_usd&.to_f }.merge(parsed).compact
        status = run.ok? ? "ok" : "error"
        error = run.error unless run.ok?

        if run.ok? && sr.step_type == "verifier"
          verdicts = Array(sr.input["verdicts"]).map(&:to_s)
          verdict = (parsed["verdict"] || text[/^\s*VERDICT:\s*([\w-]+)/i, 1]).to_s.downcase
          if verdicts.include?(verdict)
            output["verdict"] = verdict
            output["feedback"] ||= parsed["feedback"] || text.last(1500)
          else
            status = "error"
            error = "the verifier returned no verdict from #{verdicts.join(', ')}"
          end
        end
        sr.finish!(status:, output:, error:)
        Harbor::Workflows.advance_later(sr.workflow_run_id)
      end

      def parse_json(text)
        block = text.scan(JSON_BLOCK).flatten.last or return {}
        data = JSON.parse(block)
        data.is_a?(Hash) ? data : {}
      rescue JSON::ParserError
        {}
      end

      # Appended to an agent step's system prompt when it must return data.
      def instructions_for(input)
        keys = Array(input["outputs"]).map(&:to_s)
        if input["type"] == "verifier"
          verdicts = Array(input["verdicts"]).join(" | ")
          "When you finish, end your final message with a fenced ```json block: " \
            "{\"verdict\": one of #{verdicts}, \"feedback\": \"what must change, or why it passes\"}. " \
            "That block is read to decide what happens next."
        elsif keys.any?
          "When you finish, end your final message with a fenced ```json block containing these keys: " \
            "#{keys.join(', ')}. That block is read and passed to the next step."
        end
      end
    end
  end
end
