module Harbor
  # A site-defined flow: triggers → a graph of steps (agents, verdicts,
  # actions, waits, branches, loops). Every save is a new immutable
  # Harbor::WorkflowVersion, and runs pin the version they started on.
  #
  #   mode: off       never starts
  #         dry_run   starts on real events and records what each step WOULD
  #                   do; never runs an agent or acts outside the app, and
  #                   never claims a flow
  #         live      runs for real, and takes over the flows in `claims`
  #
  # A host extends it in a subclass named by `config.workflow_class`, as
  # with runs.
  class Workflow < ApplicationRecord
    self.table_name = "workflows"

    MODES = %w[off dry_run live].freeze
    # Where each workflow's latest definition is exported, under `config.export`.
    EXPORT_DIR = "workflows".freeze

    has_many :versions, -> { order(:number) }, class_name: "Harbor::WorkflowVersion", foreign_key: :workflow_id,
                                               dependent: :destroy, inverse_of: :workflow
    belongs_to :current_version, class_name: "Harbor::WorkflowVersion", optional: true
    has_many :workflow_runs, class_name: Harbor.class_name_for(:workflow_run_class), foreign_key: :workflow_id,
                             dependent: :destroy, inverse_of: :workflow

    validates :key, presence: true, uniqueness: true, format: { with: /\A[a-z0-9][a-z0-9-]*\z/ }
    validates :name, presence: true
    validates :mode, inclusion: { in: MODES }
    validate :claims_are_known

    scope :ordered, -> { order(:name) }
    scope :active, -> { where(mode: %w[dry_run live]) }

    def to_param = key

    def definition = Harbor::Workflows::Definition.parse(current_version&.definition || {})
    def live? = mode == "live"
    def dry_run? = mode == "dry_run"
    def off? = mode == "off"

    # Save a new version if the definition changed. Returns [version, errors].
    # `user` is the host's current user, when it has an id to record.
    def save_definition!(json_or_hash, user: nil)
      definition = Harbor::Workflows::Definition.parse(json_or_hash)
      return [ nil, definition.errors ] unless definition.valid?
      data = definition.data
      return [ current_version, [] ] if current_version && current_version.definition == data
      version = nil
      transaction do
        save! if new_record?
        number = (versions.maximum(:number) || 0) + 1
        version = versions.create!(number:, definition: data, created_by_user_id: user.try(:id))
        update!(current_version: version)
      end
      export
      [ version, [] ]
    end

    def last_run = workflow_runs.order(id: :desc).first

    def export_path = File.join(EXPORT_DIR, "#{key}.json")

    # The latest version, handed to the host to keep outside the database
    # (`config.export`). A failure is logged and never fails the save.
    def export
      hook = Harbor.config.export or return
      version = current_version or return
      hook.call(export_path, JSON.pretty_generate(
        "key" => key, "name" => name, "description" => description,
        "claims" => claims, "version" => version.number, "definition" => version.definition
      ) + "\n")
    rescue => e
      Rails.logger.error("[harbor] export of workflow #{key} failed: #{e.class}: #{e.message}")
    end

    private
      def claims_are_known
        unknown = Array(claims) - Harbor::Workflows.claimable.keys
        errors.add(:claims, "include flows that can't be claimed: #{unknown.join(', ')}") if unknown.any?
      end
  end
end
