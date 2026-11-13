module Harbor
  module AgentSession
    # The environment an agent command runs with, beyond what the runner
    # machine already has: whatever the host's `config.agent_session_env`
    # returns for the run. This is where secrets travel. The runner script
    # fetches it as a file of `export` lines and sources it, so no value is
    # ever part of a command line; Harbor computes it when asked and never
    # stores or logs it.
    module Environment
      # The host's hook returned something that can't be an environment.
      class Invalid < StandardError; end

      NAME = /\A[A-Za-z_][A-Za-z0-9_]*\z/
      # The runner script's own variables: a host can't replace them.
      RESERVED = /\AHARBOR_RUN/
      OAUTH = "CLAUDE_CODE_OAUTH_TOKEN".freeze
      API_KEY = "ANTHROPIC_API_KEY".freeze
      # How an OAuth credential begins, even when it was put in the API key.
      OAUTH_PREFIX = "sk-ant-oat".freeze

      module_function

      # NAME => value, as the host gave it. Names are checked; values are not
      # looked at.
      def for(run, provider_key)
        env = Harbor.config.agent_session_env&.call(run, provider_key) || {}
        raise Invalid, "config.agent_session_env must return a Hash, not #{env.class}" unless env.respond_to?(:to_h)

        env.to_h.each_with_object({}) do |(name, value), checked|
          name = name.to_s
          raise Invalid, "#{name.inspect} is not a valid environment variable name" unless name.match?(NAME)
          raise Invalid, "#{name} is set by the runner itself" if name.match?(RESERVED)
          checked[name] = value.to_s unless value.nil?
        end
      end

      # The file the runner sources: one `export NAME='value'` per line.
      #
      # claude takes one credential. Given both an OAuth token and an API key
      # it can pick the wrong one, so whichever the host passes, the other is
      # unset for the command, even if the machine has it. With neither,
      # nothing is touched and the machine's own login is used.
      def file(run, provider_key)
        env = self.for(run, provider_key)
        oauth = env[OAUTH].presence
        key = env[API_KEY].presence
        oauth ||= key if key&.start_with?(OAUTH_PREFIX)

        unset = []
        if oauth
          env.delete(API_KEY)
          env[OAUTH] = oauth
          unset << API_KEY
        elsif key
          unset << OAUTH
        end

        lines = unset.map { |name| "unset #{name}" } + env.map { |name, value| "export #{name}=#{quote(value)}" }
        lines.map { |line| "#{line}\n" }.join
      end

      # Single quotes take everything literally but a single quote.
      def quote(value) = "'#{value.to_s.gsub("'", %q('\\\\''))}'"
    end
  end
end
