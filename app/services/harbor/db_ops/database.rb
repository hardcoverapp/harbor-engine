require "cgi"
require "uri"

module Harbor
  module DbOps
    # One declared database (Harbor::Databases). Connection strings stay in
    # ENV: a declaration holds only names and policies, and the masking rules
    # for cleaned and staging backups are files in the host (Greenmask.rules_path).
    class Database
      Error = Harbor::Databases::Error
      VARIANTS = %w[full cleaned staging].freeze
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
      # (validate_disposable!).
      def self.protected_targets
        targets = all.select(&:configured?).map(&:source)
        targets << Target.new(ENV["DATABASE_URL"], label: Harbor::Databases.app_name.upcase_first) if ENV["DATABASE_URL"].present?
        targets
      end

      def name = @definition.label || key.tr("_", " ").titleize
      # The app's own database: read from Rails's connection instead of an ENV
      # key of its own, backed up full only (it has no masking rules) and never
      # restored to staging.
      def own? = @definition.own
      def owner = @definition.owner || "this app"
      def source_env = own? ? "DATABASE_URL" : @definition.source_env
      def source_url = own? ? self.class.own_url : ENV[source_env]
      def staging_env = own? ? nil : @definition.staging_env
      def variants_env = own? ? nil : @definition.variants_env
      def freshness_probes = @definition.freshness
      def configured? = source_url.present?
      def staging_configured? = staging_env.present? && ENV[staging_env].present?
      def source = Target.new(source_url, label: name)
      # :postgres or :mysql, from the source URL's scheme.
      def engine = configured? ? source.engine : :postgres
      def mysql? = engine == :mysql
      def staging = Target.new(staging_env && ENV[staging_env], label: "#{name} staging")

      # Full, plus each masked kind that has a rules file. MySQL: full only.
      def variants
        return [ "full" ] if own?
        chosen = variants_env && ENV[variants_env]
        return [ "full" ] if mysql? && chosen.blank?
        default = [ "full", *MASKED.select { |kind| Greenmask.rules?(key, kind) } ].join(",")
        values = (chosen || default).split(",").map(&:strip).uniq
        raise Error, "#{variants_env} must list #{VARIANTS.join(', ')}" if values.empty? || (values - VARIANTS).any?
        raise Error, "#{name} is MySQL, which gets full backups only" if mysql? && values != [ "full" ]
        (values & MASKED).each do |kind|
          next if Greenmask.rules?(key, kind)
          raise Error, "#{name}: #{kind} backups need masking rules in #{Greenmask.relative(Greenmask.rules_path(key, kind))}"
        end
        values
      end

      # What staging is refreshed from: the staging kind when this database has
      # staging rules, otherwise cleaned. Never full.
      def staging_variant
        raise Error, "#{name} is #{owner}'s own database: full backups only, never restored to staging" if own?
        raise Error, "#{name} is MySQL: full backups only, never restored to staging" if mysql?
        Greenmask.rules?(key, "staging") ? "staging" : "cleaned"
      end

      # Refuse to back up a source that has stopped receiving writes: a frozen
      # database is nearly always a fork or a decommissioned cluster. Only a
      # database declared with freshness tables is checked.
      def assert_fresh!(logger: nil)
        return true if mysql?
        return true if freshness_probes.blank?
        Freshness.assert_fresh!(source, probes: freshness_probes, max_age_days: Harbor::Setting.get(:database_max_source_age_days), logger:)
      end

      # Only the exact string "true" in the ENV key the host names.
      def self.staging_restores_enabled?
        key = Harbor.config.staging_restores_env.to_s
        key.present? && ENV[key] == "true"
      end

      OFF = "Staging restores are switched off".freeze

      def self.staging_restores_off_message
        key = Harbor.config.staging_restores_env.to_s
        key.present? ? "#{OFF}: #{key} must be true where this app runs" : OFF
      end

      def self.assert_staging_restores_enabled!
        raise Error, staging_restores_off_message unless staging_restores_enabled?
      end

      def validate_staging!
        self.class.assert_staging_restores_enabled!
        validate_disposable!(staging, hint: "staging")
      end

      def validate_disposable!(target, hint:)
        # Protect every declared source and the app itself, not just this one.
        protected = self.class.protected_targets
        # ENV may be absent in development; also protect all of Rails's own
        # databases (primary/cache/cable/queue) from their resolved config.
        ActiveRecord::Base.configurations.configs_for(env_name: Rails.env).reject(&:replica?).each do |config|
          values = config.configuration_hash
          host = values[:host].presence || "localhost"
          port = (values[:port] || 5432).to_i
          if target.host.casecmp?(host) && target.port == port && target.database == values[:database]
            raise Error, "Refusing to destroy #{Harbor::Databases.app_name}'s own #{config.name} database"
          end
        end
        protected.each { |source| target.assert_safe_to_destroy!(protected_target: source, hint:) }
        target.assert_safe_to_destroy!(hint:)
        if self.class.all.any? { |db| db.staging_configured? && db.key != key && target.same_server_and_db?(db.staging) }
          raise Error, "Destination overlaps another database's staging target"
        end
        true
      end
    end
  end
end
