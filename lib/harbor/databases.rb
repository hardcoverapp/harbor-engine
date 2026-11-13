module Harbor
  # The databases a site backs up, and the environments it restores them to.
  # Both are declared in the host's config file (Harbor::ConfigFile, by default
  # `config/harbor.yml`). Connection strings are secrets, so they stay in ENV:
  # the file names the ENV keys, never the URLs.
  #
  #   databases:
  #     ledger:
  #       source_env: LEDGER_DB_URL              # what is backed up (read only)
  #       variants_env: LEDGER_BACKUP_VARIANTS   # optional: ENV listing the kinds to make
  #       freshness: { entries: created_at }     # optional: tables that prove it is live
  #     app:
  #       own: true                              # the app's own database
  #
  #   restore_environments:
  #     staging:
  #       enabled_env: STAGING_RESTORES_ENABLED  # on only when that ENV key is exactly "true"
  #       restores:
  #         - { database: ledger, backup: cleaned, target_env: LEDGER_STAGING_DB_URL }
  #
  # `own: true` is the database Rails itself is connected to: read from Rails's
  # connection, backed up in full only, and never restored anywhere.
  #
  # A restore replaces its target, and a database may be replaced for one
  # reason only: the file lists it as the `target_env` of a restore in an
  # environment the file has switched on. Environments are therefore declared
  # in the file and nowhere else.
  #
  # Databases may also be declared in Ruby, by a host that prefers code:
  #
  #   Harbor::Databases.declare "ledger", source_env: "LEDGER_DB_URL"
  #   Harbor::Databases.declare_each_time { |list| list.declare … }   # run every time the list is read
  #
  # A database declared both ways is an error.
  #
  # Nothing here needs Greenmask or any database client; those are only run by
  # a backup or a restore (Harbor::DbOps).
  module Databases
    Error = Class.new(StandardError)

    KINDS = %w[full cleaned staging].freeze
    ENV_KEY = /\A[A-Za-z_][A-Za-z0-9_]*\z/

    Definition = Struct.new(:key, :label, :source_env, :variants_env, :variants, :own, :owner, :freshness, keyword_init: true)
    # One line of an environment's `restores:`. `backup` is the kind the file
    # names, or nil when it names none.
    RestoreDefinition = Struct.new(:environment, :database, :backup, :target_env, keyword_init: true)
    # `enabled` is the file's literal true or false (nil when it gives
    # `enabled_env` instead, or neither).
    EnvironmentDefinition = Struct.new(:key, :name, :enabled, :enabled_env, :restores, keyword_init: true)

    # Collects declarations, refusing a name that couldn't be a folder or a
    # second database of the same name.
    class List
      KEY = /\A[a-z][a-z0-9_]*\z/

      def initialize
        @definitions = {}
        @from_file = []
      end

      def declare(key, source_env: nil, variants_env: nil, variants: nil, own: false, owner: nil, freshness: nil, label: nil, **removed)
        key = key.to_s
        if removed.key?(:staging_env)
          raise Error, "Database #{key}: staging_env: is gone. Declare what is restored where under restore_environments in #{ConfigFile.label}"
        end
        raise ArgumentError, "unknown keyword: #{removed.keys.map(&:inspect).join(', ')}" if removed.any?
        raise Error, "Database names must use lowercase letters, numbers and underscores" unless key.match?(KEY)
        raise Error, "Database #{key} is declared in #{ConfigFile.label} and in Ruby" if @from_file.include?(key)
        raise Error, "Database #{key} is declared twice" if @definitions.key?(key)
        raise Error, "Database #{key} needs source_env:, the ENV key holding its URL" unless own || source_env.present?
        raise Error, "Database #{key}: give variants or variants_env, not both" if variants && variants_env.present?
        kinds = variants && Array(variants).map(&:to_s)
        raise Error, "Database #{key}: variants must list #{KINDS.join(', ')}" if kinds && (kinds.empty? || (kinds - KINDS).any?)
        [ source_env, variants_env ].compact.each { |name| Databases.assert_env_key!(name.to_s, "Database #{key}") }

        @definitions[key] = Definition.new(key:, label: label.presence, source_env: source_env&.to_s,
                                           variants_env: variants_env&.to_s, variants: kinds&.uniq&.freeze,
                                           own: own ? true : false, owner: owner.presence,
                                           freshness: (freshness || {}).to_h.transform_keys(&:to_s).transform_values(&:to_s).freeze)
      end

      def declared?(key) = @definitions.key?(key.to_s)

      def definitions = @definitions.values

      # Take the config file's databases first; a later declaration of one of
      # them in Ruby is then refused by name.
      def from_file!(other)
        other.definitions.each { |definition| @definitions[definition.key] = definition }
        @from_file = other.definitions.map(&:key)
        self
      end

      def merge!(other)
        other.definitions.each do |definition|
          raise Error, "Database #{definition.key} is declared in #{ConfigFile.label} and in Ruby" if @from_file.include?(definition.key)
          raise Error, "Database #{definition.key} is declared twice" if declared?(definition.key)
          @definitions[definition.key] = definition
        end
        self
      end
    end

    # Turns the config file's two sections into definitions, refusing anything
    # it doesn't understand: a key it doesn't know is far more likely a typo
    # than something to skip.
    class FileReader
      DATABASE_KEYS = %w[source_env variants_env variants own owner freshness label].freeze
      ENVIRONMENT_KEYS = %w[name enabled enabled_env restores].freeze
      RESTORE_KEYS = %w[database backup target_env].freeze
      ENVIRONMENT_KEY = /\A[a-z][a-z0-9_-]*\z/
      # An environment's restores run as the operation "<key>-restore", which
      # must not be mistaken for one of the two fixed operations.
      RESERVED = %w[db database].freeze

      def initialize(label)
        @label = label
      end

      def databases(section)
        list = List.new
        section.each do |key, options|
          at("databases.#{key}") do
            options = mapping(options)
            unknown!(options, DATABASE_KEYS)
            boolean!(options, "own")
            raise Error, "freshness must map tables to timestamp columns" unless options["freshness"].nil? || options["freshness"].is_a?(Hash)
            raise Error, "variants must be a list" unless options["variants"].nil? || options["variants"].is_a?(Array)
            list.declare(key.to_s, **options.transform_keys(&:to_sym))
          end
        end
        list
      end

      # `known` is every declared database, by key, wherever it was declared.
      def environments(section, known)
        seen = {}
        section.map do |key, options|
          key = key.to_s
          at("restore_environments.#{key}") do
            raise Error, "environment keys use lowercase letters, numbers, hyphens and underscores" unless key.match?(ENVIRONMENT_KEY)
            raise Error, "#{key} is a reserved name" if RESERVED.include?(key)
            options = mapping(options)
            unknown!(options, ENVIRONMENT_KEYS)
            boolean!(options, "enabled")
            raise Error, "give enabled or enabled_env, not both" if options.key?("enabled") && options.key?("enabled_env")
            Databases.assert_env_key!(options["enabled_env"], "enabled_env") if options.key?("enabled_env")
            restores = options["restores"]
            raise Error, "restores must be a list" unless restores.nil? || restores.is_a?(Array)
            EnvironmentDefinition.new(key:, name: options["name"].presence&.to_s || key.tr("_-", " ").titleize,
                                      enabled: options["enabled"], enabled_env: options["enabled_env"],
                                      restores: Array(restores).each_with_index.map { |entry, index| restore(key, entry, index, known, seen) }.freeze)
          end
        end
      end

      private
        def restore(environment, entry, index, known, seen)
          at("restore_environments.#{environment}.restores[#{index}]") do
            entry = mapping(entry)
            unknown!(entry, RESTORE_KEYS)
            database = entry["database"].to_s
            raise Error, "needs database:, the database it restores" if database.empty?
            definition = known[database]
            raise Error, "unknown database #{database}" unless definition
            raise Error, "#{database} is #{definition.owner || 'this app'}'s own database: full backups only, never restored" if definition.own
            raise Error, "needs target_env:, the ENV key holding the URL of the database it replaces" if entry["target_env"].blank?
            Databases.assert_env_key!(entry["target_env"], "target_env")
            backup = entry.key?("backup") ? entry["backup"].to_s : nil
            raise Error, "unknown backup kind #{backup.inspect} (expected #{KINDS.join(', ')})" if backup && !KINDS.include?(backup)

            target_env = entry["target_env"].to_s
            raise Error, "#{database} is already restored in #{environment}" if seen.key?([ environment, database ])
            raise Error, "target #{target_env} is already the target of #{seen[target_env]}" if seen.key?(target_env)
            seen[[ environment, database ]] = true
            seen[target_env] = "restore_environments.#{environment} (#{database})"
            RestoreDefinition.new(environment:, database:, backup:, target_env:)
          end
        end

        # Name the file and the entry in whatever went wrong inside the block.
        def at(entry)
          yield
        rescue Error, ArgumentError => error
          raise Error, "#{@label}: #{entry}: #{error.message}"
        end

        def mapping(value)
          return {} if value.nil?
          raise Error, "must be a mapping" unless value.is_a?(Hash)
          value.transform_keys(&:to_s)
        end

        def unknown!(options, allowed)
          unknown = options.keys - allowed
          raise Error, "unknown key #{unknown.join(', ')} (expected #{allowed.join(', ')})" if unknown.any?
        end

        # Only YAML's true and false: "yes please" must not read as on.
        def boolean!(options, name)
          return unless options.key?(name)
          raise Error, "#{name} must be true or false" unless [ true, false ].include?(options[name])
        end
    end

    class << self
      def declare(key, **options) = fixed.declare(key, **options)

      def declare_each_time(&block)
        raise ArgumentError, "declare_each_time needs a block" unless block
        blocks << block
      end

      # Every declared database: the file's, then those declared in Ruby, in
      # the order declared. Raises Error when a declaration is invalid.
      def definitions
        list = List.new.from_file!(file_databases).merge!(fixed)
        blocks.each { |block| block.call(list) }
        list.definitions
      end

      def any? = definitions.any?

      # Every restore environment the file declares, in its order. Raises
      # Error when the file, a database declaration or an environment is
      # invalid.
      def environments
        section = file_section("restore_environments")
        return [] if section.empty?
        known = definitions.index_by(&:key)
        FileReader.new(ConfigFile.label).environments(section, known)
      end

      # What is wrong with what is declared, as messages: none when it is all
      # valid. Logged when the app boots; the page and every operation raise
      # the same errors when they read the declarations.
      def problems
        [ -> { definitions }, -> { environments } ].filter_map do |read|
          read.call && nil
        rescue Error => error
          error.message
        end.uniq
      end

      # What the app that owns the `own: true` database is called in messages.
      def app_name
        definitions.find(&:own)&.owner || "this app"
      rescue Error
        "this app"
      end

      # A `Harbor.config` value that may be given as a callable, which is then
      # read each time it is needed.
      def setting(name)
        value = Harbor.config.public_send(name)
        value.respond_to?(:call) ? value.call : value
      end

      # The file names ENV keys. A URL pasted where a key belongs would put a
      # password in the repository, so it is refused outright.
      def assert_env_key!(name, what)
        return if name.is_a?(String) && name.match?(ENV_KEY)
        raise Error, "#{what} must name an ENV key (letters, numbers and underscores), never hold the value itself"
      end

      # Read the config file again the next time it is needed.
      def reload!
        ConfigFile.reload!
        @file_databases = nil
      end

      # Tests only.
      def reset!
        @fixed = nil
        @blocks = nil
        reload!
      end

      private
        def fixed = (@fixed ||= List.new)
        def blocks = (@blocks ||= [])

        def file_section(name)
          ConfigFile.section(name)
        rescue ConfigFile::Error => error
          raise Error, error.message
        end

        # Parsed once per version of the file's `databases:` section.
        def file_databases
          section = file_section("databases")
          cached = @file_databases
          return cached.last if cached && cached.first.equal?(section)
          list = FileReader.new(ConfigFile.label).databases(section)
          @file_databases = [ section, list ]
          list
        end
    end
  end
end
