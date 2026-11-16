module Harbor
  module Machines
    # Makes the machine a run was placed on and starts the run's command
    # there (Provisioner). `create` can take many minutes, so it runs here
    # and never in a request. `attempt` is the start of the session this
    # belongs to: a job left over from an earlier one does nothing.
    class ProvisionJob < ActiveJob::Base
      queue_as :default

      def perform(run_id, attempt, options = {})
        run = Harbor.run_class.find_by(id: run_id) or return
        Provisioner.new(run, attempt:, **options.to_h.symbolize_keys.slice(:command, :base, :title, :bundle)).call
      end
    end
  end
end
