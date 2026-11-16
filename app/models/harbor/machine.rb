module Harbor
  # A machine made for one run by an environment recipe (Harbor::Machines):
  # one row for each run placed on an "Orca (per workspace)" runtime. The row
  # is written before `create` runs and outlives the run, so a machine is
  # never lost track of: it is done with only when it was removed, when its
  # recipe removes nothing, or when a person said it is gone.
  #
  #   creating       `create` is to run, or running (`beat_at` says it is
  #                  still at it)
  #   created        `create` returned a result: the machine is up
  #   uncertain      `create` started and ended without a result (it failed,
  #                  overran, was stopped, or the app went down under it): a
  #                  machine may or may not exist
  #   destroyed      `destroy` removed it
  #   destroy_skipped  the recipe says `destroy: none`; nothing was run
  #   forgotten      a person said it is gone
  #
  # What `create` printed holds the machine's pairing code, which controls
  # it. It is kept here and nowhere else, encrypted with a key made from the
  # app's `secret_key_base`, for as long as the machine may be up, and emptied
  # when it is done with.
  class Machine < ApplicationRecord
    self.table_name = "harbor_machines"
    self.filter_attributes += [ :sealed_result ]

    LIVE = %w[creating created uncertain].freeze
    DONE = %w[destroyed destroy_skipped forgotten].freeze
    STATUSES = (LIVE + DONE).freeze
    PURPOSE = "harbor.machine".freeze

    belongs_to :runtime, class_name: Harbor.class_name_for(:runtime_class), optional: true

    validates :status, inclusion: { in: STATUSES }
    validates :instance_id, :recipe, :run_id, presence: true

    scope :live, -> { where(status: LIVE) }
    scope :done, -> { where(status: DONE) }

    STATUSES.each { |name| define_method("#{name}?") { status == name } }

    def live? = LIVE.include?(status)
    def done? = DONE.include?(status)

    def run = Harbor.run_class.find_by(id: run_id)

    # What `create` printed, as a Hash, or nil when there is none (or it can
    # no longer be read: the app's secret changed).
    def result
      return nil if sealed_result.blank?
      JSON.parse(self.class.encryptor.decrypt_and_verify(sealed_result, purpose: PURPOSE))
    rescue ActiveSupport::MessageEncryptor::InvalidMessage, JSON::ParserError
      nil
    end

    def result=(hash)
      self.sealed_result = hash.nil? ? nil : self.class.encryptor.encrypt_and_sign(JSON.generate(hash), purpose: PURPOSE)
    end

    def pairing_code = result.to_h["pairingCode"].presence
    def project_root = result.to_h["projectRoot"].presence

    # The recipe as declared now, or nil when the file no longer has it (or
    # can't be read).
    def declared_recipe
      Harbor::EnvironmentRecipes.find(recipe)
    rescue Harbor::EnvironmentRecipes::Error
      nil
    end

    def recipe_name = declared_recipe&.name || recipe_snapshot["name"].presence || recipe

    def self.encryptor
      @encryptor ||= ActiveSupport::MessageEncryptor.new(Rails.application.key_generator.generate_key(PURPOSE, 32))
    end
  end
end
