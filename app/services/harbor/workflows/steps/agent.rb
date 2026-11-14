module Harbor
  module Workflows
    module Steps
      # "agent" and "verifier": the step's agent runs as an agent session.
      module Agent
        def self.start(_engine, _step, step_run, _input)
          Harbor::Workflows::AgentStep.dispatch!(step_run)
          :blocked
        end
      end
    end
  end
end
