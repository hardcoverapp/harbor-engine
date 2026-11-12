module Harbor
  # A Markdown document an agent is given along with its system prompt, named
  # by a relative path ("style/tone.md").
  class AgentDocument < ApplicationRecord
    self.table_name = "agent_documents"

    belongs_to :agent, class_name: Harbor.class_name_for(:agent_class), inverse_of: :agent_documents

    validates :path, presence: true, uniqueness: { scope: :agent_id }
    validates :path, format: { with: /\A(?!\/)(?!.*(?:\A|\/)\.\.(?:\/|\z)).+\.md\z/i }
    validate do
      errors.add(:path, "Edit AGENT.md in the system prompt field.") if path.to_s.casecmp?("AGENT.md")
    end
  end
end
