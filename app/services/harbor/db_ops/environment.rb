module Harbor
  module DbOps
    # One restore environment from the config file (Harbor::Databases): a named
    # set of databases, each replaced with a saved backup of a declared
    # database. "Staging" is one; a site may have several, called anything.
    #
    # Whether an environment is on is decided in the file and nowhere else:
    # `enabled: true`, or `enabled_env:` naming an ENV key that must be exactly
    # "true". There is no setting, no param and no method here that turns one
    # on.
    class Environment
      Error = Harbor::Databases::Error

      attr_reader :key

      def self.all = Harbor::Databases.environments.map { |definition| new(definition) }

      def self.find!(key)
        raise Error, "No restore environment was named" if key.blank?
        all.find { |environment| environment.key == key.to_s } || raise(Error, "Unknown restore environment #{key}")
      end

      def initialize(definition)
        @definition = definition
        @key = definition.key
      end

      def name = @definition.name
      def enabled_env = @definition.enabled_env

      # The name its restores run under: what the host's `database_operation`
      # is called with and what the runs are filed as.
      def operation = "#{key}-restore"

      def enabled?
        return ENV[enabled_env] == "true" if enabled_env
        @definition.enabled == true
      end

      # What decides it, in words. Names the ENV key or the file's line, never
      # a value.
      def switch
        file = Harbor::ConfigFile.label
        if enabled_env
          enabled? ? "#{enabled_env} is true where this app runs" : "set #{enabled_env}=true where this app runs (#{file} names that key)"
        else
          enabled? ? "enabled: true in #{file}" : "set enabled: true for #{key} in #{file}"
        end
      end

      def off_message
        reason = enabled_env ? "#{enabled_env} must be true where this app runs" : "set enabled: true for #{key} in #{Harbor::ConfigFile.label}"
        "#{name} restores are switched off: #{reason}"
      end

      def assert_enabled!
        raise Error, off_message unless enabled?
      end

      def restores = @definition.restores.map { |definition| RestoreEntry.new(self, definition) }

      def restore_of!(database_key)
        restores.find { |entry| entry.database.key == database_key.to_s } ||
          raise(Error, "#{database_key} is not restored in #{key}: #{Harbor::ConfigFile.label} lists no such restore")
      end
    end
  end
end
