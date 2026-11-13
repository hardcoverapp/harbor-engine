require "cgi"
require "uri"

module Harbor
  module DbOps
    # One declared database (Harbor::Databases). Connection strings stay in
    # ENV: a declaration holds only names and policies, and the masking rules
    # for cleaned and staging backups are files in the host (Greenmask.rules_path).
    class Database
      Error = Harbor::Databases::Error
      VARIANTS = Harbor::Databases::KINDS
      # Kinds made with masking rules (see Greenmask.rules_path).
      MASKED = %w[cleaned staging].freeze

      attr_reader :key

      def self.all = Harbor::Databases.definitions.map { |definition| new(definition) }

      def self.find!(key)
        all.find { |db| db.key == key } || raise(Error, "Unknown database")
      end

      def initialize(definition)
        @definition = definition
        @key = definition.key
      end

      # A postgres:// URL for this environment's primary database (the one
      # Rails is connected to; in tests, the test database), or nil when Rails
      # connects without a host and user (a local socket), which pg_dump can't
      # be pointed at.
      def self.own_url
        config = ActiveRecord::Base.configurations.configs_for(env_name: Rails.env, name: "primary")&.configuration_hash
        return nil unless config && config[:host].present? && config[:username].present? && config[:database].present?
        userinfo = [ config[:username], config[:password].presence ].compact.map { |part| CGI.escape(part.to_s) }.join(":")
        URI::Generic.build(scheme: "postgres", userinfo:, host: config[:host].to_s, port: config[:port]&.to_i,
                           path: "/#{Target::PARSER.escape(config[:database].to_s)}").to_s
      end

      # Everything a restore must never replace: every declared database's
      # source, and the database the app itself runs on. Rails's other
      # databases are refused separately, from their resolved config
      # (RestoreEntry#validate!).
      def self.protected_targets
        targets = all.select(&:configured?).map(&:source)
        targets << Target.new(ENV["DATABASE_URL"], label: Harbor::Databases.app_name.upcase_first) if ENV["DATABASE_URL"].present?
        targets
      end

      def name = @definition.label || key.tr("_", " ").titleize
      # The app's own database: read from Rails's connection instead of an ENV
      # key of its own, backed up full only (it has no masking rules) and never
      # restored anywhere.
      def own? = @definition.own
      def owner = @definition.owner || "this app"
      def source_env = own? ? "DATABASE_URL" : @definition.source_env
      def source_url = own? ? self.class.own_url : ENV[source_env]
      def variants_env = own? ? nil : @definition.variants_env
      def freshness_probes = @definition.freshness
      def configured? = source_url.present?
      def source = Target.new(source_url, label: name)
      # :postgres or :mysql, from the source URL's scheme.
      def engine = configured? ? source.engine : :postgres
      def mysql? = engine == :mysql

      # Where the config file restores this database: one entry per
      # environment that lists it.
      def restores = Environment.all.flat_map(&:restores).select { |entry| entry.database.key == key }
      def restore_in(environment_key) = restores.find { |entry| entry.environment.key == environment_key.to_s }

      def restore_in!(environment_key)
        restore_in(environment_key) || raise(Error, "#{name} is not restored in #{environment_key}: #{Harbor::ConfigFile.label} lists no such restore")
      end

      # Full, plus each masked kind that has a rules file. MySQL: full only.
      def variants
        return [ "full" ] if own?
        chosen = @definition.variants&.join(",") || (variants_env && ENV[variants_env])
        return [ "full" ] if mysql? && chosen.blank?
        default = [ "full", *MASKED.select { |kind| Greenmask.rules?(key, kind) } ].join(",")
        values = (chosen || default).split(",").map(&:strip).uniq
        raise Error, "#{variants_env || "#{name}'s variants"} must list #{VARIANTS.join(', ')}" if values.empty? || (values - VARIANTS).any?
        raise Error, "#{name} is MySQL, which gets full backups only" if mysql? && values != [ "full" ]
        (values & MASKED).each do |kind|
          next if Greenmask.rules?(key, kind)
          raise Error, "#{name}: #{kind} backups need masking rules in #{Greenmask.relative(Greenmask.rules_path(key, kind))}"
        end
        values
      end

      # Refuse to back up a source that has stopped receiving writes: a frozen
      # database is nearly always a fork or a decommissioned cluster. Only a
      # database declared with freshness tables is checked.
      def assert_fresh!(logger: nil)
        return true if mysql?
        return true if freshness_probes.blank?
        Freshness.assert_fresh!(source, probes: freshness_probes, max_age_days: Harbor::Setting.get(:database_max_source_age_days), logger:)
      end
    end
  end
end
