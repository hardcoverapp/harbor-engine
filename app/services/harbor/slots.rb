module Harbor
  # Atomic capacity reservations, kept in Redis. A line (an agent, a runtime)
  # has two budgets: how many sessions run at once, and how many workspaces
  # they occupy. Sessions that share a workspace count once against the
  # second. A reservation is a lease with an owner and an expiry, so one that
  # is never given back (a killed worker) frees itself.
  #
  # `holder` is anything with `key`, `max_agents` and `max_workspaces`: an
  # agent, or a Capacity made for the purpose.
  module Slots
    Capacity = Struct.new(:key, :max_agents, :max_workspaces)

    # One ledger per line tracks both budgets. Expiry lives on each lease, so
    # changing a limit never hides live work.
    LEDGER = <<~LUA.freeze
      local entries = redis.call('HGETALL', KEYS[1])
      local leases, workspaces, busy, workspace_count = {}, {}, 0, 0
      for i = 1, #entries, 2 do
        local lease = cjson.decode(entries[i + 1])
        if lease.expires <= tonumber(ARGV[1]) then
          redis.call('HDEL', KEYS[1], entries[i])
        else
          leases[entries[i]] = lease
          busy = busy + 1
          if not workspaces[lease.workspace] then
            workspaces[lease.workspace] = true
            workspace_count = workspace_count + 1
          end
        end
      end
      if ARGV[2] == 'acquire' then
        if busy >= tonumber(ARGV[3]) then return -1 end
        if not workspaces[ARGV[5]] and workspace_count >= tonumber(ARGV[4]) then return -1 end
        local slot = 0
        while leases[tostring(slot)] do slot = slot + 1 end
        redis.call('HSET', KEYS[1], tostring(slot), cjson.encode({owner=ARGV[6], workspace=ARGV[5], expires=tonumber(ARGV[1])+tonumber(ARGV[7])}))
        return slot
      end
      return {busy, workspace_count}
    LUA

    RELEASE = <<~LUA.freeze
      local raw = redis.call('HGET', KEYS[1], ARGV[1])
      if raw and cjson.decode(raw).owner == ARGV[2] then redis.call('HDEL', KEYS[1], ARGV[1]) end
    LUA

    module_function

    # The Redis key of a line's ledger (`config.slot_key`).
    def ledger_key(line) = Harbor.config.slot_key.call(line.to_s)

    # [sessions running, workspaces in use] on the holder's line.
    def counts(holder)
      Harbor.redis { |r| r.call("EVAL", LEDGER, 1, ledger_key(holder.key), Time.now.to_i, "counts") }
    end

    def busy(holder) = counts(holder).first

    def free(holder)
      sessions, workspaces = counts(holder)
      [ [ holder.max_agents - sessions, holder.max_workspaces - workspaces ].min, 0 ].max
    end

    # Take a slot for `owner`, for `ttl` seconds. `workspace` names the
    # workspace the session uses, when it shares one. Returns the slot's
    # number, or nil when the line is full.
    def acquire(holder, owner, ttl:, workspace: nil)
      slot = Harbor.redis do |r|
        r.call("EVAL", LEDGER, 1, ledger_key(holder.key), Time.now.to_i, "acquire",
               holder.max_agents, holder.max_workspaces, workspace || owner, owner, ttl)
      end
      slot == -1 ? nil : slot
    end

    # Give a slot back. Owner-checked: a slot that has since gone to other
    # work is left alone.
    def release(line, slot, owner)
      return if line.nil? || slot.nil?
      Harbor.redis { |r| r.call("EVAL", RELEASE, 1, ledger_key(line), slot, owner) }
    end

    # Forget every lease on a line (after a restart, when nothing is running).
    def clear(line) = Harbor.redis { |r| r.call("DEL", ledger_key(line)) }
  end
end
