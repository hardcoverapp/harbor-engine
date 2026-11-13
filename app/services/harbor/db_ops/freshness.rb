module Harbor
  module DbOps
    # "Is this database still being written to?"
    #
    # Exists because of a live incident: a source URL pointed at a cluster
    # whose every table had stopped months earlier. It was a fork or an
    # abandoned cluster, not a replica, so nothing about the connection looked
    # wrong. Left unchecked that would have spent every backup on a dead
    # database and overwritten staging with months-old data. Both failures are
    # silent: the dump succeeds, the restore succeeds.
    #
    # The host says which tables prove a database is live (`freshness:` on its
    # declaration): table => timestamp column, all tried, the newest across
    # those that exist wins. The probe reads the newest row via the primary
    # key rather than max() on a timestamp column, so it stays fast on very
    # large tables.
    module Freshness
      Error = Class.new(StandardError)

      module_function

      # Newest write we can see, or nil when no probe table exists / is populated.
      def newest_write(target, probes:, logger: nil)
        stamps = probes.filter_map do |table, column|
          newest_in(target, table, column)
        end
        stamps.max.tap do |newest|
          logger&.call("[freshness] #{target.redacted}: newest write #{newest || 'unknown'}")
        end
      end

      def newest_in(target, table, column)
        # to_regclass keeps a missing table from erroring the whole probe, and the
        # PK-ordered LIMIT 1 avoids a seq scan on a multi-GB table.
        sql = <<~SQL.squish
          SELECT CASE WHEN to_regclass('public.#{table}') IS NULL THEN NULL ELSE (
            SELECT #{column}::text FROM public.#{table} ORDER BY id DESC LIMIT 1
          ) END
        SQL
        out = Pg.capture!([ "psql", "-tAX", "-c", sql, target.url_without_password ],
                          targets: [ target ], logger: nil)
        out.presence && Time.parse(out)
      rescue StandardError
        nil
      end

      def age_days(newest) = newest.nil? ? nil : ((Time.now.utc - newest.utc) / 86_400.0)

      # Raise when the source has not been written to recently enough to be the
      # live database. `nil` (nothing to probe) is NOT treated as stale — an empty
      # database is a legitimate state and this must not block a first run.
      def assert_fresh!(target, probes:, max_age_days:, logger: nil)
        newest = newest_write(target, probes:, logger:)
        return true if newest.nil?

        age = age_days(newest)
        return true if age <= max_age_days.to_f

        raise Error, "#{target.redacted} looks abandoned: its newest write is #{newest.utc} " \
                     "(#{age.round} days old, limit #{max_age_days}). A database that stopped " \
                     "receiving writes is usually a fork or a decommissioned cluster rather than " \
                     "the live one — check the URL. Raise \"Newest write allowed\" on the " \
                     "Settings page if this really is correct."
      end
    end
  end
end
