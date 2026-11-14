module Harbor
  # One entry in the review policy: a risk (what kind of change a pull request
  # is), a check (a piece of evidence, with outputs, pass_when and
  # then-routing) or a sign-off (a person who must approve). Every save is an
  # immutable version, so a check run can pin the version it ran and a bad
  # edit is one click back.
  #
  #   mode: live    affects the round and its verdict
  #         shadow  runs and records on every round, affects nothing
  #         off     never runs
  #
  # `repo` is the repository the rule is for, or "*" for every one. A host
  # with columns or rules of its own subclasses this and names the subclass
  # (`config.review_rule_class`).
  class ReviewRule < ApplicationRecord
    self.table_name = "review_rules"

    KINDS = %w[risk check signoff].freeze
    MODES = %w[live shadow off].freeze

    has_many :versions, -> { order(:number) }, class_name: Harbor.class_name_for(:review_rule_version_class),
                                               foreign_key: :review_rule_id, inverse_of: :review_rule, dependent: :destroy
    belongs_to :current_version, class_name: Harbor.class_name_for(:review_rule_version_class), optional: true

    validates :kind, inclusion: { in: KINDS }
    validates :mode, inclusion: { in: MODES }
    validates :name, presence: true
    validates :key, presence: true, format: { with: /\A[a-z0-9][a-z0-9_-]*\z/ },
                    uniqueness: { scope: %i[kind repo] }

    scope :risks,    -> { where(kind: "risk") }
    scope :checks,   -> { where(kind: "check") }
    scope :signoffs, -> { where(kind: "signoff") }
    scope :running,  -> { where(mode: %w[live shadow]) }
    scope :for_repo, ->(repo) { where(repo: [ "*", repo.to_s ]) }

    # What a new rule starts with on the page, beyond its kind and shadow
    # mode. A host's subclass adds its own (the repository it reviews).
    def self.page_defaults = {}

    # The definition the form for a new rule of this kind starts with.
    def self.definition_template(kind) = Harbor::Reviews::RuleDefinition.template(kind)

    def definition = current_version&.definition || {}
    def live? = mode == "live"
    def shadow? = mode == "shadow"
    def version_number = current_version&.number

    # Save a new version if the definition changed. Returns [version, errors].
    # `user` is the host's user who saved it, when it has one.
    def save_definition!(hash, user: nil)
      data = Harbor::Reviews::RuleDefinition.normalize(kind, hash)
      errors = Harbor::Reviews::RuleDefinition.errors(kind, data)
      return [ nil, errors ] if errors.any?
      return [ current_version, [] ] if current_version && current_version.definition == data

      version = nil
      transaction do
        save! if new_record?
        number = (versions.maximum(:number) || 0) + 1
        version = versions.create!(number:, definition: data, created_by_user_id: user.try(:id))
        update!(current_version: version)
      end
      Harbor::Reviews::Export.write(self)
      [ version, [] ]
    end

    # Point the rule back at an earlier version (as a new version, so history stays linear).
    def roll_back_to!(number, user: nil)
      old = versions.find_by!(number:)
      save_definition!(old.definition, user:)
    end
  end
end
