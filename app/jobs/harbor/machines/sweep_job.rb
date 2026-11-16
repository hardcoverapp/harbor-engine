module Harbor
  module Machines
    # The sweep as a job: removes the machines finished runs left behind
    # (Harbor::Machines.sweep). A site that has an "Orca (per workspace)"
    # runtime gives its scheduler this, every few minutes, beside the
    # automations tick. The button on a runtime's page runs it for that
    # runtime, at once.
    class SweepJob < ActiveJob::Base
      queue_as :default

      def perform(runtime_id = nil, force = false)
        runtime = runtime_id && Harbor.runtime_class.find_by(id: runtime_id)
        return if runtime_id && runtime.nil?
        report = Harbor::Machines.sweep(runtime:, force:)
        Rails.logger.info("[harbor] machine sweep: #{report.summary}")
        report
      end
    end
  end
end
