require "yaml"

module Harbor
  module DbOps
    # Runs the Greenmask CLI (https://greenmask.io), which makes every database
    # backup: a `full` dump with no rules, and a masked dump that applies the
    # host's rules file while it reads, so no scratch database is needed and
    # production is only ever read.
    #
    # Greenmask is needed only when a backup runs or a dump is pruned. Nothing
    # here runs when the app boots or the page is drawn.
    #
    # Each dump is a directory (toc.dat, metadata.json and one compressed file
    # per table) named by Greenmask's dump id, a millisecond timestamp:
    #
    #   <storage>/<dump id>/
    #
    # Storage is <backup root>/<database>/<full|cleaned|staging>/, and a bucket
    # mirrors the same layout, so `greenmask restore latest` works against
    # either one. Both pg_restore and `greenmask restore` read the dump.
    #
    # Credentials stay out of argv and the generated config: the connection
    # string has no password, which arrives via PGPASSFILE (see Pg.with_pgpass).
    module Greenmask
      Error = Class.new(StandardError)
      DUMP_ID = /\A\d{13}\z/

      module_function

      def binary = Harbor::Databases.setting(:greenmask_bin).to_s

      # Greenmask shells out to pg_dump/pg_restore from here; they must be at
      # least the server's major version (see Pg.assert_client_new_enough!).
      # Unless the host names the folder, it is wherever pg_dump is on the PATH.
      def pg_bin_path
        configured = Harbor::Databases.setting(:greenmask_pg_bin_path).to_s
        return configured if configured.present?
        found = ENV["PATH"].to_s.split(File::PATH_SEPARATOR).find { |dir| File.executable?(File.join(dir, "pg_dump")) }
        found || raise(Error, "pg_dump not found on PATH; set config.greenmask_pg_bin_path")
      end

      # The host's folder of masking rules (`config.masking_rules_path`).
      def rules_dir = Pathname(Harbor::Databases.setting(:masking_rules_path).to_s)

      # Masked kinds and where their rules live:
      #   cleaned  <rules>/<database>.yml          (safe to hand to developers)
      #   staging  <rules>/staging/<database>.yml  (staging only: may keep more)
      def rules_path(database_key, variant = "cleaned")
        variant == "staging" ? rules_dir.join("staging", "#{database_key}.yml") : rules_dir.join("#{database_key}.yml")
      end

      # A rules path as it reads in a message: from the app's root when it is
      # inside the app.
      def relative(path)
        path = Pathname(path.to_s)
        path.to_s.start_with?("#{Rails.root}/") ? path.relative_path_from(Rails.root) : path
      end

      def rules?(database_key, variant = "cleaned") = File.file?(rules_path(database_key, variant))

      # The `dump:` section of a rules file.
      def rules(database_key, variant = "cleaned")
        path = rules_path(database_key, variant)
        relative = self.relative(path)
        raise Error, "No #{variant} masking rules at #{relative}" unless File.file?(path)
        dump = YAML.safe_load_file(path).to_h["dump"]
        raise Error, "#{relative} must have a top-level dump: section" unless dump.is_a?(Hash)
        dump
      end

      def directory_storage(path) = { "type" => "directory", "directory" => { "path" => path.to_s } }

      def config(storage:, tmp_dir:, dump: nil)
        config = { "common" => { "pg_bin_path" => pg_bin_path, "tmp_dir" => tmp_dir.to_s },
                   "log" => { "level" => "info", "format" => "text" },
                   "storage" => storage }
        config["dump"] = dump if dump
        config
      end

      # Dump `target` into storage_dir and return the new dump id. `rules` is the
      # parsed dump: section for a cleaned backup, or nil for a full one.
      # `progress` (optional) is called every PROGRESS_INTERVAL seconds with the
      # bytes written so far.
      def dump(target, storage_dir:, tmp_dir:, rules: nil, jobs: nil, logger: nil, progress: nil)
        FileUtils.mkdir_p(storage_dir)
        before = dump_ids(storage_dir)
        dump = (rules || {}).deep_dup
        options = (dump["pg_dump_options"] || {}).merge("dbname" => conninfo(target))
        options["jobs"] = jobs.to_i if jobs.to_i > 1
        dump["pg_dump_options"] = options
        watcher = watch(storage_dir, before, progress, logger) if progress
        begin
          run!(target, config(storage: directory_storage(storage_dir), tmp_dir:, dump:), %w[dump],
               tmp_dir:, logger:, what: "greenmask dump #{target.redacted}")
        rescue StandardError
          # A failed dump leaves a partial directory behind; never keep it.
          (dump_ids(storage_dir) - before).each { |id| FileUtils.rm_rf(File.join(storage_dir, id)) }
          raise
        ensure
          watcher&.kill
        end
        created = dump_ids(storage_dir) - before
        raise Error, "greenmask dump finished but no new dump appeared in #{storage_dir}" unless created.size == 1
        id = created.first
        raise Error, "greenmask dump #{id} is incomplete (no metadata.json)" unless File.file?(File.join(storage_dir, id, "metadata.json"))
        id
      end

      # Keep the newest `keep` completed dumps in this storage and remove failed
      # ones. A keep below 1 would delete every backup, so it is refused.
      def prune(storage:, tmp_dir:, keep:, logger: nil)
        keep = keep.to_i
        raise Error, "refusing to prune with keep=#{keep}; that would delete every backup" if keep < 1
        run!(nil, config(storage:, tmp_dir:), [ "delete", "--retain-recent", keep.to_s, "--prune-failed" ],
             tmp_dir:, logger:, what: "greenmask delete")
      end

      PROGRESS_INTERVAL = 5

      # Measure the new dump directory while Greenmask writes it. Runs on its own
      # thread (and DB connection); a failure here never affects the dump.
      def watch(storage_dir, before, progress, logger, interval: PROGRESS_INTERVAL)
        Thread.new do
          loop do
            sleep interval
            id = (dump_ids(storage_dir) - before).first
            bytes = id ? LocalStore.size(File.join(storage_dir, id)) : 0
            Rails.application.executor.wrap { progress.call(bytes) }
          rescue StandardError => e
            logger&.call("[progress] #{e.class}: #{e.message}")
          end
        end
      end

      def dump_ids(dir)
        return [] unless File.directory?(dir)
        Dir.children(dir).select { |name| name.match?(DUMP_ID) && File.directory?(File.join(dir, name)) }
      end

      # libpq keyword conninfo without the password (Greenmask and pg_dump both
      # read PGPASSFILE).
      def conninfo(target)
        parts = { "host" => target.host, "port" => target.port, "user" => target.user, "dbname" => target.database }
        parts.merge(target.params).map { |key, value| "#{key}=#{quote(value)}" }.join(" ")
      end

      def quote(value)
        text = value.to_s
        text.match?(/\A[^\s'\\]+\z/) ? text : "'#{text.gsub(/[\\']/) { "\\#{_1}" }}'"
      end

      def run!(target, config, args, tmp_dir:, logger:, what:)
        FileUtils.mkdir_p(tmp_dir)
        file = File.join(tmp_dir, "greenmask-#{SecureRandom.hex(4)}.yml")
        File.write(file, config.to_yaml)
        File.chmod(0o600, file)
        command = [ binary, "--config", file, *args ]
        if target
          Pg.run!(command, targets: [ target ], logger:, what:)
        else
          Pg.stream_cmd!(Pg.base_env, command, logger:, what:)
        end
      rescue Errno::ENOENT
        raise Error, "greenmask is not installed (looked for #{binary}); install it where the app runs, or set config.greenmask_bin"
      ensure
        FileUtils.rm_f(file) if file
      end
    end
  end
end
