require "uri"
require "cgi"

module Harbor
  module DbOps
    # One database, parsed out of a postgres:// URL.
    #
    # Two jobs beyond parsing:
    #
    # 1. Keep the password out of argv and out of logs. `pg_dump "$URL"` puts the
    #    password in `ps` for every process on the box, and any log line echoing
    #    the URL leaks it into the run's live log, which is served to every
    #    logged-in user. Callers get #url_without_password + #pgpass_line
    #    (see DbOps::Pg.with_pgpass) and #redacted for logging.
    #
    # 2. Answer "is it safe to destroy this one?". A staging restore drops
    #    every schema before restoring; pointed at the wrong URL that is an
    #    unrecoverable production wipe. See #assert_safe_to_destroy!.
    class Target
      Error = Class.new(StandardError)

      # URL scheme => engine. MySQL databases get full backups with
      # mysqldump; see DbOps::Mysql.
      ENGINES = { "postgres" => :postgres, "postgresql" => :postgres, "mysql" => :mysql }.freeze
      DEFAULT_PORTS = { postgres: 5432, mysql: 3306 }.freeze
      ALLOWED_PARAMS = {
        postgres: %w[sslmode sslrootcert sslcert sslkey connect_timeout application_name target_session_attrs],
        # mysql client option names (managed MySQL usually needs ssl-mode=REQUIRED).
        mysql: %w[ssl-mode ssl-ca ssl-cert ssl-key]
      }.freeze

      # Percent-escaping as URLs for libpq are written. Newer versions of the
      # uri library warn when it is reached through DEFAULT_PARSER.
      PARSER = defined?(URI::RFC2396_PARSER) ? URI::RFC2396_PARSER : URI::DEFAULT_PARSER

      attr_reader :url, :label

      def initialize(url, label: nil)
        @url = url.to_s
        raise Error, "#{label || 'database'} URL is blank" if @url.strip.empty?

        @uri = URI.parse(@url)
        unless ENGINES.key?(@uri.scheme)
          raise Error, "#{label || 'database'} URL scheme #{@uri.scheme.inspect} is not postgres:// or mysql://"
        end
        @label = label
        unless @uri.fragment.nil? && @uri.host.present? && @uri.user.present? && @uri.path.to_s.match?(%r{\A/[^/]+\z})
          raise Error, "#{label || 'database'} URL requires a host, user and database name"
        end
        unless (params.keys - ALLOWED_PARAMS.fetch(engine)).empty?
          raise Error, "#{label || 'database'} URL has unsupported connection parameters"
        end
      rescue URI::InvalidURIError
        raise Error, "#{label || 'database'} URL is not parseable"
      end

      def host     = @uri.host.to_s
      def engine   = ENGINES.fetch(@uri.scheme)
      def mysql?   = engine == :mysql
      def port     = (@uri.port || DEFAULT_PORTS.fetch(engine)).to_i
      def user     = CGI.unescape(@uri.user.to_s)
      def password = CGI.unescape(@uri.password.to_s)
      def database = PARSER.unescape(@uri.path.to_s.delete_prefix("/"))
      def params   = URI.decode_www_form(@uri.query.to_s).to_h

      # Safe to log and to show on a run's page: no password, ever.
      def redacted = "#{user}@#{host}:#{port}/#{database}"
      def to_s     = redacted
      def inspect  = "#<Harbor::DbOps::Target #{redacted}>"

      # Conninfo safe to pass as a command argument: everything except the
      # password, which comes from PGPASSFILE instead (see DbOps::Pg.with_pgpass).
      # Keeping the full URL out of argv matters because argv is world-readable in
      # `ps`, and because a pipeline needs TWO different credentials at once —
      # which single-valued PGPASSWORD cannot express.
      def url_without_password
        u = @uri.dup
        u.password = nil
        u.to_s
      end

      def with_application_name(name)
        u = @uri.dup
        u.query = URI.encode_www_form(params.merge("application_name" => name))
        self.class.new(u.to_s, label:)
      end

      # One .pgpass line. Colons and backslashes in any field must be escaped or
      # libpq mis-parses the line and silently fails to find the password.
      def pgpass_line
        [ host, port, database, user, password ]
          .map { |f| f.to_s.gsub("\\", "\\\\\\\\").gsub(":", "\\:") }
          .join(":")
      end

      def same_server_and_db?(other)
        other.is_a?(Target) && host.casecmp?(other.host) && port == other.port &&
          database.casecmp?(other.database)
      end

      # Does this look like a throwaway environment? Deliberately conservative:
      # the name has to SAY so. A DB that merely isn't the configured production
      # one is not automatically safe (there is more than one production system).
      def looks_disposable?(hint: "staging")
        h = hint.to_s.downcase
        database.downcase.include?(h) || host.downcase.include?(h)
      end

      # Gate for anything that drops schemas. Raises unless the target both
      # (a) isn't the protected database, and (b) names itself disposable.
      # The ENV switch the host names (`config.unsafe_restore_env`) set to
      # "true" overrides (b) only; (a) is absolute.
      def assert_safe_to_destroy!(protected_target: nil, hint: "staging")
        if protected_target && same_server_and_db?(protected_target)
          raise Error, "refusing to destroy #{redacted}: it is the same server+database as " \
                       "#{protected_target.label || 'the protected database'} " \
                       "(#{protected_target.redacted}). Check the URLs — this would have " \
                       "dropped the production schema."
        end
        return true if looks_disposable?(hint:)
        override = Harbor.config.unsafe_restore_env.to_s
        if override.present? && ENV[override].to_s == "true"
          return true
        end
        raise Error, "refusing to destroy #{redacted}: neither the database name nor the host " \
                     "contains #{hint.inspect}, so this does not look like a disposable " \
                     "environment.#{" Set #{override}=true if it really is." if override.present?}"
      end

      # Redact any password that appears in text destined for a log.
      def self.scrub(text)
        text.to_s.gsub(%r{((?:postgres(?:ql)?|mysql)://[^:@/\s]+:)([^@/\s]+)(@)}, '\1<redacted>\3')
      end
    end
  end
end
