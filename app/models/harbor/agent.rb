require "marcel"

module Harbor
  # An agent: a name, the instructions it works from (a system prompt plus any
  # number of documents), the tools it may use and the model alias it runs on.
  # A host extends it in a subclass named by `config.agent_class`, as with
  # runs: where its runs execute, for one.
  class Agent < ApplicationRecord
    self.table_name = "agents"

    AVATAR_CONTENT_TYPES = %w[image/png image/jpeg image/gif image/webp].freeze
    MAX_AVATAR_SIZE = 2.megabytes

    # An uploaded image file, stored on the record when it saves.
    attr_accessor :avatar
    attribute :remove_avatar, :boolean, default: false
    before_validation :assign_avatar
    validate :validate_avatar

    belongs_to :model_alias, class_name: Harbor.class_name_for(:model_alias_class), optional: true
    has_many :agent_documents, class_name: "Harbor::AgentDocument", foreign_key: :agent_id,
             dependent: :destroy, inverse_of: :agent
    accepts_nested_attributes_for :agent_documents, allow_destroy: true, reject_if: :all_blank
    has_many :task_assignments, class_name: "Harbor::TaskAssignment", foreign_key: :agent_key, primary_key: :key,
             dependent: :nullify, inverse_of: :agent

    validates :key, presence: true, uniqueness: true
    validates :key, format: { with: /\A[a-z0-9][a-z0-9_-]*\z/ }
    validate do
      errors.add(:tools, "must be a JSON object") unless tools.is_a?(Hash)
      errors.add(:configuration, "must be a JSON object") unless configuration.is_a?(Hash)
      errors.add(:default_tasks, "must be a JSON array") unless default_tasks.is_a?(Array)
    end

    scope :enabled, -> { where(enabled: true) }

    def display_name = name.presence || key

    def avatar? = avatar_data.present? && AVATAR_CONTENT_TYPES.include?(avatar_content_type)

    # Everything the agent is told before its task: what every agent is told,
    # then its own prompt, then its documents.
    def full_system_prompt
      [ self.class.house_context, system_prompt,
        *agent_documents.map { |doc| "# #{doc.path}\n\n#{doc.body}" } ].compact_blank.join("\n\n---\n\n")
    end

    # What every agent is told: the house context, then each shared document.
    def self.house_context
      [ AgentSetting.find_by(key: AgentSetting::HOUSE_CONTEXT)&.body,
        *AgentSetting.shared_documents.map { |doc| "# #{doc.key.delete_prefix(AgentSetting::SHARED_PREFIX)}\n\n#{doc.body}" }
      ].compact_blank.join("\n\n---\n\n")
    end

    private

    def assign_avatar
      if avatar.present?
        unless avatar.respond_to?(:read) && avatar.respond_to?(:rewind)
          errors.add(:avatar, "must be an image file")
          return
        end
        avatar.rewind
        self.avatar_data = avatar.read(MAX_AVATAR_SIZE + 1).to_s
        self.avatar_content_type = Marcel::MimeType.for(StringIO.new(avatar_data))
      elsif remove_avatar
        self.avatar_data = nil
        self.avatar_content_type = nil
      end
    end

    def validate_avatar
      return if avatar_data.nil?
      errors.add(:avatar, "must be a PNG, JPEG, GIF, or WebP image") unless AVATAR_CONTENT_TYPES.include?(avatar_content_type)
      errors.add(:avatar, "must be 2 MB or smaller") if avatar_data.bytesize > MAX_AVATAR_SIZE
    end
  end
end
