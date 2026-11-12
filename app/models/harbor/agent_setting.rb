module Harbor
  # Text every agent is given: the house context (one row) and any number of
  # shared documents, keyed "shared/<path>.md".
  class AgentSetting < ApplicationRecord
    self.table_name = "agent_settings"

    HOUSE_CONTEXT = "house_context".freeze
    SHARED_PREFIX = "shared/".freeze

    validates :key, presence: true, uniqueness: true

    scope :shared_documents, -> { where("key LIKE ?", "#{sanitize_sql_like(SHARED_PREFIX)}%").order(:key) }
  end
end
