module Harbor
  # A name agents are given instead of a model ("Thinking", "Quick"): an
  # ordered list of choices, so the model behind the name can change, and fall
  # back to another provider, without touching any agent. A host extends it in
  # a subclass named by `config.model_alias_class`, as with runs.
  class ModelAlias < ApplicationRecord
    self.table_name = "model_aliases"

    class Unavailable < StandardError; end

    has_many :model_choices, -> { order(:position, :id) }, class_name: "Harbor::ModelChoice",
             foreign_key: :model_alias_id, dependent: :destroy, inverse_of: :model_alias
    accepts_nested_attributes_for :model_choices, allow_destroy: true, reject_if: :all_blank

    validates :name, presence: true, uniqueness: true
    validate :has_choices

    # The first choice whose provider is switched on and below the choice's
    # cutoff. `backend`, when given, is where the run will execute: anything
    # answering `supports?(choice, **policy)`, `label` and
    # `policy_hint(**policy)`; a choice it can't run is passed over. Raises
    # Unavailable when no choice is left.
    def resolve(backend: nil, **policy)
      choice = model_choices.includes(:model_provider).detect do |candidate|
        candidate.model_provider.below_cutoff?(candidate.cutoff_percent) &&
          (backend.nil? || backend.supports?(candidate, **policy))
      end
      return choice if choice

      where = backend ? ", or unsupported at #{backend.label}" : ""
      raise Unavailable, "No available model for #{name}: providers are disabled or above their usage cutoff#{where}. " \
                         "Check the Models page.#{backend&.policy_hint(**policy)}"
    end

    private

    def has_choices
      errors.add(:base, "Add at least one model.") if model_choices.reject(&:marked_for_destruction?).empty?
    end
  end
end
