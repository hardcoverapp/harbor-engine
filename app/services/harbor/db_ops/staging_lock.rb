module Harbor
  module DbOps
    module StagingLock
      CONNECTION_ENV = { "PGOPTIONS" => "-c default_transaction_read_only=off" }.freeze
      module_function

      def with_lock(target, logger:)
        # Lock the role the staging app connects as (the one in the URL
        # unless the host names another), while only our child processes
        # override read-only. Never change the worker's process-wide ENV.
        role = Harbor::Databases.setting(:staging_lock_role).presence || target.user
        target = target.with_application_name(application_name)
        quoted = %Q("#{role.gsub('"', '""')}")
        literal = role.gsub("'", "''")
        configured = Pg.capture!([ "psql", "-tAX", "-c",
                                   "SELECT COALESCE('default_transaction_read_only=on' = ANY(rolconfig), false) FROM pg_roles WHERE rolname = '#{literal}'",
                                   target.url_without_password ], targets: [ target ], logger:)
        if configured == "t"
          raise Pg::Error, "Staging role #{quoted} is already read-only; check for an active restore before unlocking it"
        end
        Pg.exec_sql(target, "ALTER ROLE #{quoted} SET default_transaction_read_only = on", logger:, env: CONNECTION_ENV, label: "lock staging app role")
        locked = true
        drain(target, role, logger:)
        yield target, CONNECTION_ENV
      ensure
        if locked
          unlock(target, quoted, logger:)
          drain(target, role, logger:)
        end
      end

      def unlock(target, quoted, logger:)
        3.times do |attempt|
          begin
            Pg.exec_sql(target, "ALTER ROLE #{quoted} RESET default_transaction_read_only", logger:, env: CONNECTION_ENV, label: "unlock staging app role")
            return
          rescue StandardError => e
            logger&.call("[restore] unlock attempt #{attempt + 1} failed: #{Target.scrub(e.message)}")
            raise Pg::Error, "Could not unlock staging app role #{quoted}; reset default_transaction_read_only manually" if attempt == 2
          end
        end
      end

      def application_name = Harbor.config.restore_application_name.to_s

      # Connections a drain leaves alone: this restore's own, and those of any
      # other application the host says to spare.
      def spared_applications
        names = [ *Array(Harbor.config.restore_spared_applications).map(&:to_s), application_name ].uniq
        names.map { |name| "'#{name.gsub("'", "''")}'" }.join(", ")
      end

      def drain(target, role, logger:)
        literal = role.gsub("'", "''")
        spared = spared_applications
        Pg.exec_sql(target, <<~SQL, logger:, env: CONNECTION_ENV, label: "drain staging app connections")
          DO $$ DECLARE i integer; BEGIN
            FOR i IN 1..10 LOOP
              PERFORM pg_terminate_backend(pid) FROM pg_stat_activity
                WHERE usename = '#{literal}' AND datname = current_database() AND pid <> pg_backend_pid()
                  AND application_name NOT IN (#{spared})
                  AND (i = 10 OR state IN ('idle', 'idle in transaction'));
              PERFORM pg_stat_clear_snapshot();
              EXIT WHEN NOT EXISTS (
                SELECT 1 FROM pg_stat_activity
                WHERE usename = '#{literal}' AND datname = current_database() AND pid <> pg_backend_pid()
                  AND application_name NOT IN (#{spared})
              );
              PERFORM pg_sleep(2);
              PERFORM pg_stat_clear_snapshot();
            END LOOP;
          END $$;
        SQL
      end
    end
  end
end
