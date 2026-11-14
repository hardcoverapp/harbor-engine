module Harbor
  module Workflows
    module Steps
      # The "note" action: a line in the app's log.
      module Note
        def self.start(engine, _step, step_run, input)
          message = input["message"].to_s
          Rails.logger.info("[harbor] workflow note (run #{engine.run.id}): #{message}")
          step_run.finish!(status: "ok", output: { "message" => message })
          :done
        end
      end
    end
  end
end
