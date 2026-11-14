module Harbor
  # Text every agent is given: the house context (one row) and any number of
  # shared documents, keyed "shared/<path>.md".
  class AgentSetting < ApplicationRecord
    self.table_name = "agent_settings"

    HOUSE_CONTEXT = "house_context".freeze
    SHARED_PREFIX = "shared/".freeze

    # The keys the Agents page may write: the house context, and a shared
    # document's ("shared/guides/tone.md").
    SHARED_DOCUMENT = %r{\Ashared/[a-zA-Z0-9_./-]+\.md\z}

    validates :key, presence: true, uniqueness: true

    def self.editable_key?(key) = key == HOUSE_CONTEXT || key.to_s.match?(SHARED_DOCUMENT)

    scope :shared_documents, -> { where("key LIKE ?", "#{sanitize_sql_like(SHARED_PREFIX)}%").order(:key) }
  end
end
