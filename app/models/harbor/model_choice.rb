module Harbor
  # One model in an alias's ordered list: which provider's model, at what
  # effort, and the usage percentage past which the next choice is used.
  class ModelChoice < ApplicationRecord
    self.table_name = "model_choices"

    EFFORTS = %w[none minimal low medium high xhigh max ultra].freeze

    belongs_to :model_alias, class_name: Harbor.config.model_alias_class, inverse_of: :model_choices
    belongs_to :model_provider, class_name: "Harbor::ModelProvider"

    validates :model, presence: true
    validates :effort, inclusion: { in: EFFORTS }, allow_blank: true
    validates :position, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
    validates :cutoff_percent, numericality: { only_integer: true, greater_than: 0, less_than_or_equal_to: 100 }
    validate do
      openai_model = model.to_s.match?(/\A(?:gpt-|o\d)/)
      if model_provider && openai_model != (model_provider.key == "openai")
        errors.add(:model, "does not match its provider")
      end
    end
  end
end
