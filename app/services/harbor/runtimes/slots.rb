module Harbor
  module Runtimes
    # How many workspaces a runtime has in use, against its limit. A run needs
    # a slot on its runtime as well as one of its agent's. Sessions aren't
    # limited per runtime, only workspaces; sessions sharing a workspace count
    # once.
    module Slots
      UNLIMITED = 1_000_000

      module_function

      # A runtime's line in the ledger, from the runtime or its key.
      def line(runtime) = "runtime:#{runtime.respond_to?(:key) ? runtime.key : runtime}"

      def capacity(runtime) = Harbor::Slots::Capacity.new(line(runtime), UNLIMITED, runtime.max_concurrent)

      def busy(runtime) = Harbor::Slots.counts(capacity(runtime)).last

      def acquire(runtime, owner, ttl:, workspace: nil)
        Harbor::Slots.acquire(capacity(runtime), owner, ttl:, workspace:)
      end

      def release(runtime_key, slot, owner)
        return if runtime_key.nil? || slot.nil?
        Harbor::Slots.release(line(runtime_key), slot, owner)
      end

      # After a restart nothing is executing, so leases on a runtime with no
      # running run are left over from the last process.
      def release_stale!
        Harbor.runtime_class.find_each do |runtime|
          next if Harbor.run_class.where(runtime_id: runtime.id, status: "running").exists?
          Harbor::Slots.clear(line(runtime))
        end
      end
    end
  end
end
