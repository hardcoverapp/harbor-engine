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
    # 2. Answer "is this the same database as that one?", so a restore can
    #    refuse a target that is really a source. See #assert_distinct_from!.
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

      LOOPBACK = %w[localhost 127.0.0.1 ::1 [::1]].freeze

      # The host as two URLs for one server are compared: without case, without
      # the trailing dot of a fully qualified name, and with every spelling of
      # this machine as one. Two different names for one server (an IP address
      # and a DNS name, say) are not known to be the same.
      def server = self.class.server_name(host)

      def self.server_name(host)
        name = host.to_s.downcase.chomp(".")
        LOOPBACK.include?(name) ? "localhost" : name
      end

      # The same database on the same server: host (see #server), port (the
      # engine's default when the URL names none) and database name, the name
      # without case and after percent-decoding. The user, password and
      # connection parameters play no part.
      def same_server_and_db?(other)
        other.is_a?(Target) && server == other.server && port == other.port &&
          database.casecmp?(other.database)
      end

      # Refuse to replace this database when it is the protected one. A restore
      # drops every schema first; pointed at the wrong URL that is an
      # unrecoverable production wipe. Nothing overrides this.
      #
      # This is the only thing a target itself is asked. What it is called
      # proves nothing, so its name is never looked at: a database may be
      # replaced because the config file lists it, and for no other reason
      # (see DbOps::RestoreEntry#validate!).
      def assert_distinct_from!(protected_target)
        return true unless same_server_and_db?(protected_target)
        raise Error, "refusing to destroy #{redacted}: it is the same server+database as " \
                     "#{protected_target.label || 'the protected database'} " \
                     "(#{protected_target.redacted}). Check the URLs — this would have " \
                     "dropped the production schema."
      end

      # Redact any password that appears in text destined for a log.
      def self.scrub(text)
        text.to_s.gsub(%r{((?:postgres(?:ql)?|mysql)://[^:@/\s]+:)([^@/\s]+)(@)}, '\1<redacted>\3')
      end
    end
  end
end
