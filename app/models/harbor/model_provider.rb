module Harbor
  # A company whose models agents run on, with a switch and the subscription
  # usage last read for it. A model is only chosen from a provider that is
  # switched on and below the choice's usage cutoff.
  class ModelProvider < ApplicationRecord
    self.table_name = "model_providers"

    NAMES = { "anthropic" => "Anthropic", "openai" => "OpenAI" }.freeze
    KEYS = NAMES.keys.freeze

    has_many :model_choices, class_name: "Harbor::ModelChoice", dependent: :restrict_with_error

    validates :key, inclusion: { in: KEYS }, uniqueness: true
    validates :session_used_percent, :weekly_used_percent,
              numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 100 }, allow_nil: true

    def display_name = NAMES.fetch(key, key.to_s)

    # Whether an API key for this provider is in the environment (a secret, so
    # never a setting).
    def key_configured? = ENV["#{key.upcase}_API_KEY"].present?

    # The share of a usage window ("session" or "weekly") that is spent, or nil
    # when it isn't known or the window has since reset.
    def usage_percent(window)
      reset = public_send("#{window}_resets_at")
      return nil if reset && reset <= Time.current
      public_send("#{window}_used_percent")
    end

    def below_cutoff?(cutoff)
      enabled? && %w[session weekly].all? { |window| usage_percent(window).nil? || usage_percent(window) < cutoff }
    end
  end
end
