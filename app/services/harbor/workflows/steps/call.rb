module Harbor
  module Workflows
    module Steps
      # "call": starts another workflow with this run's trigger and the step's
      # input, and waits for it. The child hands its result back when it
      # finishes (Engine#notify_parent).
      module Call
        def self.start(engine, step, step_run, input)
          run = engine.run
          target = Harbor.workflow_class.find_by(key: input["workflow"])
          raise ArgumentError, "no workflow with key #{input['workflow'].inspect}" unless target&.current_version
          child = Harbor::Workflows.start!(target, trigger: run.context["trigger"].to_h, kind: "workflow",
                                                   input: input["input"].to_h, parent: run, parent_step_key: step["key"])
          raise ArgumentError, "couldn't start #{target.key}" unless child
          step_run.update!(output: { "child_run_id" => child.id })
          :blocked
        end
      end
    end
  end
end
