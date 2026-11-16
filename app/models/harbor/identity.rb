module Harbor
  # An account agents act as: a name people recognise, the service it is an
  # account of, its login there, and the NAME of the environment variable that
  # holds its token. The token itself is never stored: it is read from that
  # variable when a session asks for it, and is in no column, log, page, error
  # or job argument.
  #
  #   bot = Harbor::Identity.create!(name: "Release bot", login: "release-bot", token_env: "GITHUB_PAT_RELEASE_BOT")
  #   agent.update!(identity: bot)
  #
  # An agent with an identity has its sessions started as that account
  # (Harbor::AgentSession::Environment); one with none acts as nobody.
  class Identity < ApplicationRecord
    self.table_name = "harbor_identities"

    # A variable that an identity names is not set where the app runs.
    class TokenMissing < StandardError; end

    # What an identity can be an account of: for each kind, what a person
    # calls it, how one of its logins is written, and what a session acting
    # as one is given. Another service is another entry here.
    Kind = Struct.new(:label, :login_format, :login_hint, :handle, :session_env, keyword_init: true)
    KINDS = {
      "github" => Kind.new(
        label: "GitHub",
        login_format: /\A[A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?\z/,
        login_hint: "is a GitHub username: letters, digits and dashes",
        handle: ->(login) { "@#{login}" },
        # gh and git both act as the account: the token under the two names
        # tools read, and commits written under the login, with the address
        # GitHub gives every account.
        session_env: lambda do |login, token|
          email = "#{login}@users.noreply.github.com"
          { "GH_TOKEN" => token, "GITHUB_TOKEN" => token,
            "GIT_AUTHOR_NAME" => login, "GIT_AUTHOR_EMAIL" => email,
            "GIT_COMMITTER_NAME" => login, "GIT_COMMITTER_EMAIL" => email }
        end
      )
    }.freeze
    DEFAULT_KIND = "github".freeze
    # The same rule as a runtime's pairing code and API key variables.
    ENV_NAME = /\A[A-Z_][A-Z0-9_]*\z/
    TOKEN_TYPED = "is named by an environment variable, like GITHUB_PAT_RELEASE_BOT, not typed here".freeze

    has_many :agents, class_name: Harbor.class_name_for(:agent_class), foreign_key: :identity_id, inverse_of: :identity

    before_validation { self.kind = kind.presence || DEFAULT_KIND }
    validates :name, presence: true, uniqueness: { case_sensitive: false }
    validates :kind, inclusion: { in: KINDS.keys }
    validates :login, presence: true, uniqueness: { scope: :kind, case_sensitive: false }
    validate :login_reads_as_one
    validate :token_env_names_a_variable
    before_destroy :refuse_while_used

    scope :by_name, -> { order(Arel.sql("lower(name)"), :id) }

    # The identity with this login, whatever its case; nil for none.
    def self.with_login(login)
      login = login.to_s.strip
      login.blank? ? nil : where("lower(login) = ?", login.downcase).order(:id).first
    end

    # Who a run acts as. The run's own `acting_as` (an automation's "run as",
    # or what a host wrote there) names an identity by its login, and wins
    # over the agent's; a name that is no identity's is the host's business
    # and gets nothing of Harbor's. With none, the agent's identity.
    def self.for_run(run, agent: nil)
      named = run.try(:acting_as).presence
      return with_login(named) if named

      agent ||= run.try(:agent_key).presence && Harbor.agent_class.find_by(key: run.agent_key)
      agent&.identity
    end

    # A login is written without its "@".
    def login=(value)
      super(value.to_s.strip.delete_prefix("@").presence)
    end

    # Only a variable's name is ever kept. Anything else (a token pasted in)
    # is dropped here, before it can reach the record, a query, the form shown
    # again or a log line; the validation then says why.
    def token_env=(value)
      value = value.to_s.strip
      @token_typed = value.present? && !value.match?(ENV_NAME)
      super(@token_typed ? nil : value.presence)
    end

    def kind_definition = KINDS.fetch(kind.presence || DEFAULT_KIND, KINDS.fetch(DEFAULT_KIND))
    def kind_label = kind_definition.label
    # The login as the service writes it ("@release-bot").
    def handle = kind_definition.handle.call(login)
    # How it reads in a list of identities to pick from.
    def label = "#{name} (#{handle})"

    # The token, read now from the variable; nil when it isn't set here.
    def token = token_env.present? ? ENV[token_env].presence : nil
    def token_set? = token.present?

    # The token, or TokenMissing saying which variable (never a value).
    def token!
      token || raise(TokenMissing, "the identity #{name} (#{handle}) has no token here: #{token_env} isn't set")
    end

    # What a session acting as this account is given. Raises TokenMissing.
    def session_env = kind_definition.session_env.call(login, token!)

    # The automations told to run as this account, by its login.
    def automations = Harbor.automation_class.where("lower(run_as) = ?", login.to_s.downcase)

    private

    def login_reads_as_one
      return if login.blank?
      errors.add(:login, kind_definition.login_hint) unless login.match?(kind_definition.login_format)
    end

    def token_env_names_a_variable
      if @token_typed
        errors.add(:base, "The token #{TOKEN_TYPED}.")
      elsif token_env.blank?
        errors.add(:base, "Name the environment variable that holds the token, like GITHUB_PAT_RELEASE_BOT.")
      elsif !token_env.match?(ENV_NAME)
        # Set some other way than the writer above (update_column, SQL).
        errors.add(:base, "The token #{TOKEN_TYPED}.")
      end
    end

    def refuse_while_used
      used = []
      keys = agents.order(:key).map(&:display_name)
      used << "#{'agent'.pluralize(keys.size)} #{keys.to_sentence}" if keys.any?
      names = automations.order(:name).pluck(:name)
      used << "#{'automation'.pluralize(names.size)} #{names.to_sentence}" if names.any?
      return if used.empty?

      errors.add(:base, "#{name} is used by the #{used.to_sentence}. Give them another identity first.")
      throw :abort
    end
  end
end
