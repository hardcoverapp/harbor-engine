require "open3"
require "tempfile"

module Harbor
  module DbOps
    # Full backups of MySQL databases with mysqldump. MySQL gets full backups
    # only: no masking, so these dumps never go to staging or developers.
    #
    # A dump is a folder like the Greenmask ones, so the catalog, locations,
    # progress and retention treat both alike:
    #
    #   <root>/<database>/full/<dump id>/<database>.sql.gz   (+ manifest.json)
    #
    # Restore with: gunzip -c <database>.sql.gz | mysql <database>
    #
    # The password never reaches argv: the client reads it from a private
    # option file (--defaults-extra-file), removed when the command ends.
    module Mysql
      Error = Class.new(StandardError)

      module_function

      def dump_name(database_key) = "#{database_key}.sql.gz"

      def server_version(target, logger: nil)
        out = capture!(target, [ "mysql", "--batch", "--skip-column-names", "-e", "SELECT VERSION()" ], logger:)
        out.lines.last.to_s.strip
      end

      # Dump `target` into dir/<database>.sql.gz. --single-transaction reads a
      # consistent snapshot without locking InnoDB tables, so the site keeps
      # working during the dump.
      def dump(target, dir:, database_key:, logger: nil)
        FileUtils.mkdir_p(dir)
        path = File.join(dir, dump_name(database_key))
        with_option_file(target) do |options|
          args = [ "mysqldump", "--defaults-extra-file=#{options}", "--single-transaction", "--quick",
                   "--routines", "--triggers", "--hex-blob", "--no-tablespaces", "--set-gtid-purged=OFF",
                   # MariaDB and older servers lack the statistics table mysqldump 8 queries.
                   "--column-statistics=0", "--default-character-set=utf8mb4", target.database ]
          script = "set -o pipefail; #{Pg.shell_join(args)} | gzip -6 > #{Pg.shell_join([ path ])}"
          logger&.call("[mysql] mysqldump #{target.redacted} → #{File.basename(path)}")
          Pg.stream_shell!({}, script, logger:, what: "mysqldump #{target.redacted}")
        end
        raise Error, "mysqldump wrote nothing for #{target.redacted}" unless File.size?(path).to_i.positive?
        path
      end

      # Data + index bytes of the database's tables, for the first backup's
      # progress readout. nil on error.
      def table_data_bytes(target, logger: nil)
        sql = "SELECT COALESCE(SUM(data_length + index_length), 0) FROM information_schema.tables WHERE table_schema = DATABASE()"
        capture!(target, [ "mysql", "--batch", "--skip-column-names", target.database, "-e", sql ], logger:).to_i
      rescue StandardError
        nil
      end

      def capture!(target, args, logger: nil)
        with_option_file(target) do |options|
          out, err, status = Open3.capture3(args.first, "--defaults-extra-file=#{options}", *args.drop(1))
          raise Error, "#{args.first} failed: #{Target.scrub(err).strip.last(500)}" unless status.success?
          logger&.call("[mysql] #{Target.scrub(err).strip}") if err.to_s.strip.present?
          out
        end
      end

      # [client] option file with the connection, password included, mode 0600.
      def with_option_file(target)
        file = Tempfile.new("harbor-mysql")
        File.chmod(0o600, file.path)
        lines = [ "[client]", "host=#{target.host}", "port=#{target.port}", "user=#{target.user}",
                  "password=#{option_value(target.password)}" ]
        target.params.each { |key, value| lines << "#{key}=#{option_value(value)}" }
        # Only the mysql client knows this option; mysqldump rejects it in [client].
        lines += [ "[mysql]", "connect-timeout=#{Harbor::Setting.get(:database_connect_timeout)}" ]
        file.write(lines.join("\n") + "\n")
        file.flush
        yield file.path
      ensure
        file&.close
        file&.unlink
      end

      # Option-file values are quoted so #, ; and spaces in passwords survive.
      def option_value(value) = %("#{value.to_s.gsub('\\', '\\\\\\\\').gsub('"', '\\"')}")
    end
  end
end
