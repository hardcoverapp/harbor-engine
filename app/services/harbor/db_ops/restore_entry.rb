module Harbor
  module DbOps
    # One line of an environment's `restores:` in the config file: this
    # database, from this kind of backup, replaces the database whose URL is in
    # this ENV key.
    #
    # A restore drops everything in its target, and what a database is called
    # proves nothing about whether that is safe. So a target is replaceable for
    # exactly one reason: the file lists it here, in an environment the file
    # has switched on. #validate! is everything that stands in front of the
    # drop, and nothing overrides any of it.
    class RestoreEntry
      Error = Harbor::Databases::Error

      attr_reader :environment

      def initialize(environment, definition)
        @environment = environment
        @definition = definition
      end

      def database = (@database ||= Database.find!(@definition.database))
      def target_env = @definition.target_env
      # The ENV key holds something. An entry whose key is unset or blank is
      # never restored: there is no default target.
      def configured? = ENV[target_env].to_s.strip.present?
      # Raises Target::Error when the ENV key is unset, blank or not a
      # database URL.
      def target = Target.new(ENV[target_env], label: "#{database.name} #{environment.key} (#{target_env})")

      # The kind the file names for this restore, or nil when it names none.
      def named_kind = @definition.backup

      # The kind an environment restore uses: the one the file names; when it
      # names none, the staging kind if this database has staging rules,
      # otherwise cleaned. Full is used only when named.
      def kind
        raise Error, "#{database.name} is MySQL: full backups only, never restored" if database.mysql?
        named_kind || (Greenmask.rules?(database.key, "staging") ? "staging" : "cleaned")
      end

      # May this backup be restored here? Exactly the named kind; with none
      # named, any masked kind and never full.
      def accepts?(backup)
        return false unless backup.database_key == database.key
        named_kind ? backup.variant == named_kind : backup.masked?
      end

      def assert_backup!(backup)
        raise Error, "Backup belongs to another database" unless backup.database_key == database.key
        unless accepts?(backup)
          wanted = named_kind ? "a #{named_kind} backup" : "cleaned or staging backups"
          raise Error, "Only #{wanted} can be restored to #{environment.key}: #{backup.variant} is not what #{Harbor::ConfigFile.label} names"
        end
        if database.mysql? || File.file?(File.join(backup.folder, Mysql.dump_name(database.key)))
          raise Error, "#{database.name} is MySQL: full backups only, never restored"
        end
        true
      end

      # Every guard on the target, checked before a restore is queued, again
      # for every entry before an environment restore's first drop, and again
      # right before each drop. In order:
      #
      # 1. The environment is switched on, in the file.
      # 2. The target's ENV key holds a database URL (unset or blank: refused).
      # 3. It is PostgreSQL: that is all a restore knows how to replace.
      # 4. It is none of Rails's own databases.
      # 5. It is no declared database's source, and not the app's DATABASE_URL.
      # 6. No other restore in the file, in any environment, has the same
      #    target.
      def validate!
        environment.assert_enabled!
        validate_target!
      end

      # Guards 2 to 6: what is wrong with the target itself, whether or not
      # the environment is on.
      def validate_target!
        target = self.target
        raise Error, "#{target.redacted} is MySQL: a restore replaces PostgreSQL databases only" if target.mysql?
        refuse_rails_databases!(target)
        Database.protected_targets.each { |source| target.assert_distinct_from!(source) }
        refuse_shared_target!(target)
        true
      end

      # Why this entry would be refused, or nil. For the page.
      def refusal
        validate_target!
        nil
      rescue Error, Target::Error => error
        Target.scrub(error.message)
      end

      private
        # ENV may be absent in development, so Rails's databases (primary,
        # cache, cable, queue) are read from their resolved configuration.
        def refuse_rails_databases!(target)
          ActiveRecord::Base.configurations.configs_for(env_name: Rails.env).reject(&:replica?).each do |config|
            values = config.configuration_hash
            host = Target.server_name(values[:host].presence || "localhost")
            port = (values[:port] || (values[:adapter].to_s.match?(/mysql|trilogy/) ? 3306 : 5432)).to_i
            next unless target.server == host && target.port == port && target.database.casecmp?(values[:database].to_s)
            raise Error, "Refusing to destroy #{Harbor::Databases.app_name}'s own #{config.name} database"
          end
        end

        def refuse_shared_target!(target)
          Environment.all.flat_map(&:restores).each do |other|
            next if other.environment.key == environment.key && other.database.key == database.key
            next unless other.configured?
            next unless target.same_server_and_db?(other.target)
            raise Error, "Destination overlaps another restore's target: #{other.database.key} in #{other.environment.key} (#{other.target_env})"
          end
        end
    end
  end
end
