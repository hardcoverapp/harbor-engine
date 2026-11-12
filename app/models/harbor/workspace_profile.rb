module Harbor
  # A workspace: a named, ordered fallback list of runtimes, as a model alias
  # is a list of models. Agents pick one; when a run needs somewhere to work,
  # #resolve walks the list and uses the first runtime that is switched on,
  # healthy, below its limit and able to run one of the agent's models. A host
  # extends it in a subclass named by `config.workspace_profile_class`.
  class WorkspaceProfile < ApplicationRecord
    self.table_name = "workspace_profiles"

    # Nothing in the list can run the agent at all. A model alias's
    # Unavailable, so the run waits for availability instead of failing.
    class Unavailable < Harbor::ModelAlias::Unavailable; end

    has_many :workspace_profile_runtimes, -> { order(:position, :id) }, class_name: "Harbor::WorkspaceProfileRuntime",
             foreign_key: :workspace_profile_id, dependent: :destroy, inverse_of: :workspace_profile
    has_many :runtimes, through: :workspace_profile_runtimes
    accepts_nested_attributes_for :workspace_profile_runtimes, allow_destroy: true, reject_if: :all_blank

    validates :key, presence: true, uniqueness: true, format: { with: /\A[a-z0-9][a-z0-9-]*\z/ }
    validates :name, presence: true, uniqueness: true
    validate :has_runtimes

    before_validation { self.key = name.to_s.parameterize if key.blank? && name.present? }

    def ordered_runtimes = workspace_profile_runtimes.reject(&:marked_for_destruction?).map(&:runtime).compact

    # See Harbor::Runtimes::Placement. Without capacity: the runtime and model
    # a run would get if it started now, ignoring limits. With capacity:
    # { owner:, ttl:, workspace: } also takes a runtime slot; the result is
    # #waiting? when every usable runtime is full.
    def resolve(agent:, run: nil, capacity: nil, **options)
      placement = Harbor::Runtimes::Placement.new(profile: self, agent:, run:, **options)
      capacity ? placement.acquire(**capacity) : placement.preview
    end

    private

    def has_runtimes
      errors.add(:base, "Add at least one runtime.") if ordered_runtimes.empty?
    end
  end
end
