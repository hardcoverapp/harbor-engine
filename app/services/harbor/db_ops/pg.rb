require "open3"
require "tempfile"

module Harbor
  module DbOps
    # Thin, logged wrappers over pg_dump / psql.
    #
    # Everything here streams: a large production dump runs for a long time, and
    # a Run whose live log only appears at the end is indistinguishable from a
    # hung one. stderr is pumped to the logger line by line, scrubbed of anything
    # that looks like a password.
    #
    # Credentials never reach argv. Commands take a password-less conninfo URL and
    # the password arrives via PGPASSFILE — which also solves the pipeline case,
    # where pg_dump and psql need two different credentials in one shell.
    module Pg
      Error = Class.new(StandardError)

      # pg_dump refuses to run against a server newer than itself, so a stale
      # client is a hard failure rather than a degraded one. Checked before any
      # long operation so it fails in seconds, not after an hour of transfer.
      MIN_SERVER_MAJOR = 16

      module_function

      def client_version
        out, _err, status = Open3.capture3("pg_dump", "--version")
        return nil unless status.success?
        out[/(\d+)\.\d+/, 1]&.to_i
      end

      def assert_client_new_enough!(server_major)
        client = client_version
        raise Error, "pg_dump not found on PATH" if client.nil?
        return true if client >= server_major.to_i
        raise Error, "pg_dump is version #{client} but the server is #{server_major} — pg_dump " \
                     "refuses to dump from a newer server. Install the PostgreSQL client tools, " \
                     "version #{server_major} or newer, where the app runs."
      end

      # Write a compressed, restorable custom-format dump to `path`.
      def dump_to_file(target, path, logger: nil, jobs: nil, exclude_table_data: [])
        args = [ "pg_dump", "-Fc", "--no-owner", "--no-acl" ]
        # -Fc is already compressed; -Z0 + parallel is a different tradeoff we
        # don't need. Parallel only works with directory format, so `jobs` is
        # accepted for symmetry but only applied when meaningful.
        args += [ "--jobs", jobs.to_s ] if jobs
        Array(exclude_table_data).each { |table| args += [ "--exclude-table-data", table ] }
        args += [ "-f", path, target.url_without_password ]
        run!(args, targets: [ target ], logger:, what: "pg_dump #{target.redacted}")
        File.size(path)
      end

      # Stream one database straight into another — no intermediate file. This is
      # the only way the staging restore fits: a production-sized dump would not
      # fit on the internal disk.
      #
      # exclude_table_data names tables whose DDL is copied but whose rows are
      # not. Unlike --exclude-table it still creates the table, so the app finds
      # it — it just arrives empty.
      def stream_dump_into(source, dest, logger: nil, exclude_table_data: [])
        src = [ "pg_dump", "--no-owner", "--no-acl" ]
        Array(exclude_table_data).each { |t| src += [ "--exclude-table-data", t ] }
        src << source.url_without_password
        dst = [ "psql", "-v", "ON_ERROR_STOP=1", "--quiet", dest.url_without_password ]
        logger&.call("[pg] streaming #{source.redacted} → #{dest.redacted}")

        with_pgpass(source, dest) do |pgpass|
          env = base_env.merge("PGPASSFILE" => pgpass)
          # pipefail: without it the exit status is psql's alone, so a pg_dump
          # that dies halfway looks like a clean restore of a truncated database.
          script = "set -o pipefail; #{shell_join(src)} | #{shell_join(dst)}"
          stream_shell!(env, script, logger:, what: "pg_dump | psql")
        end
      end

      # Clear disposable databases completely so tables absent from the backup
      # cannot survive and accidentally be included in a cleaned re-dump.
      def reset_schemas(target, logger: nil, env: {})
        sql = <<~SQL
          DO $$ DECLARE schema_name text; BEGIN
            FOR schema_name IN SELECT nspname FROM pg_namespace
              WHERE nspname <> 'information_schema' AND nspname !~ '^pg_'
            LOOP EXECUTE format('DROP SCHEMA %I CASCADE', schema_name); END LOOP;
          END $$;
          CREATE SCHEMA public;
        SQL
        exec_sql(target, sql, logger:, env:, label: "clear disposable database schemas")
      end

      # Restore all archive objects, including schemas other than public. Refuse
      # to continue after any SQL error; an incomplete restore must fail visibly.
      def restore_file(target, path, logger: nil, env: {})
        run!([ "pg_restore", "--clean", "--if-exists", "--exit-on-error", "--no-owner", "--no-acl",
               "--dbname", target.url_without_password, path ],
             targets: [ target ], logger:, env:, what: "pg_restore #{target.redacted}")
      end

      # Run a SQL string. `label` is what shows in the log (the SQL itself may be
      # long, and may name tables we'd rather not spam into the log).
      def exec_sql(target, sql, logger: nil, label: nil, env: {})
        logger&.call("[pg] #{label || 'SQL'} on #{target.redacted}")
        run!([ "psql", "-v", "ON_ERROR_STOP=1", "--quiet", "-c", sql, target.url_without_password ],
             targets: [ target ], logger:, env:, what: label || "psql -c")
      end

      def exec_file(target, path, logger: nil, env: {})
        raise Error, "SQL file not found: #{path}" unless File.exist?(path)
        logger&.call("[pg] applying #{path} (#{File.size(path)} bytes) to #{target.redacted}")
        run!([ "psql", "-v", "ON_ERROR_STOP=1", "--quiet", "-f", path, target.url_without_password ],
             targets: [ target ], logger:, env:, what: "psql -f #{File.basename(path)}")
      end

      # Heap + TOAST bytes of every user table (no indexes): a rough scale for a
      # first backup that has no previous size to compare against. nil on error.
      def table_data_bytes(target, logger: nil)
        sql = "SELECT coalesce(sum(pg_table_size(c.oid)), 0) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace " \
              "WHERE c.relkind IN ('r', 'm') AND n.nspname NOT IN ('pg_catalog', 'information_schema') AND n.nspname !~ '^pg_toast'"
        capture!([ "psql", "-tAX", "-c", sql, target.url_without_password ], targets: [ target ], logger:).to_i
      rescue StandardError
        nil
      end

      def server_version_major(target, logger: nil)
        out = capture!([ "psql", "-tAX", "-c", "SHOW server_version", target.url_without_password ],
                       targets: [ target ], logger:)
        out[/(\d+)/, 1]&.to_i
      end

      # --- plumbing -------------------------------------------------------------

      def base_env
        {
          # A .psqlrc on the host must never inject settings into a restore.
          "PSQLRC" => "/dev/null",
          # Fail fast instead of hanging forever on an unreachable host.
          "PGCONNECT_TIMEOUT" => Harbor::Setting.get(:database_connect_timeout).to_s
        }
      end

      def with_pgpass(*targets)
        file = Tempfile.new("harbor-pgpass")
        begin
          File.chmod(0o600, file.path)
          targets.compact.each { |t| file.puts(t.pgpass_line) }
          file.flush
          yield file.path
        ensure
          file.close
          file.unlink
        end
      end

      def run!(args, targets:, logger:, what:, env: {})
        with_pgpass(*targets) do |pgpass|
          stream_cmd!(base_env.merge(env).merge("PGPASSFILE" => pgpass), args, logger:, what:)
        end
      end

      def capture!(args, targets:, logger:)
        with_pgpass(*targets) do |pgpass|
          out, err, status = Open3.capture3(base_env.merge("PGPASSFILE" => pgpass), *args)
          unless status.success?
            raise Error, "#{args.first} failed (exit #{status.exitstatus}): #{Target.scrub(err).strip.last(500)}"
          end
          logger&.call("[pg] #{Target.scrub(err).strip}") if err.to_s.strip.present?
          out.strip
        end
      end

      # Run a command, pumping stdout+stderr into the logger as they arrive.
      def stream_cmd!(env, args, logger:, what:)
        Open3.popen2e(env, *args) do |stdin, out, wait_thr|
          stdin.close
          pump(out, logger)
          status = wait_thr.value
          raise Error, "#{what} failed (exit #{status.exitstatus})" unless status.success?
        end
        true
      end

      def stream_shell!(env, script, logger:, what:)
        Open3.popen2e(env, "bash", "-c", script) do |stdin, out, wait_thr|
          stdin.close
          pump(out, logger)
          status = wait_thr.value
          raise Error, "#{what} failed (exit #{status.exitstatus})" unless status.success?
        end
        true
      end

      def pump(io, logger)
        io.each_line do |line|
          # Greenmask colours its log lines even when piped.
          line = Target.scrub(line).gsub(/\e\[[\d;]*m/, "").rstrip
          next if line.empty?
          logger&.call("[pg] #{line}")
        end
      rescue IOError
        nil
      end

      def shell_join(args) = args.map { |a| "'#{a.to_s.gsub("'", "'\\\\''")}'" }.join(" ")
    end
  end
end
