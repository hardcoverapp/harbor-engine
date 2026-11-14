module Harbor
  module Workflows
    module Steps
      # "approval": parked until a person approves or rejects on the run's
      # page (Harbor::Workflows::Control.decide!).
      module Approval
        def self.start(_engine, _step, step_run, input)
          step_run.update!(status: "waiting", output: { "prompt" => input["prompt"].presence || "Approve to continue" })
          :blocked
        end
      end
    end
  end
end
