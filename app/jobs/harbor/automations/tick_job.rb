module Harbor
  module Automations
    # The tick as a job: the one entry a site gives its scheduler, every
    # minute (README "Automations"). The work is Harbor::Automations::Tick.
    class TickJob < ActiveJob::Base
      queue_as :default

      def perform(now = Time.current) = Tick.call(now)
    end
  end
end
