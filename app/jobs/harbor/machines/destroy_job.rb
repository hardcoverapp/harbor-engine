module Harbor
  module Machines
    # Removes the machine of a run that is over (Harbor::Machines.destroy!).
    # While the machine's `create` is still being stopped it looks again
    # shortly; whatever it leaves undone, the sweep finds.
    class DestroyJob < ActiveJob::Base
      queue_as :default

      RETRY = 15.seconds
      TRIES = 20

      def perform(machine_id, try = 1)
        machine = Harbor::Machine.find_by(id: machine_id) or return
        return if machine.done?
        outcome = Harbor::Machines.destroy!(machine)
        self.class.set(wait: RETRY).perform_later(machine_id, try + 1) if outcome == :creating && try < TRIES
      end
    end
  end
end
