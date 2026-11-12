module Harbor
  # A place work can run, with a limit on how much at once: an Orca server, or
  # whatever a host's own backend drives. Workspaces list runtimes in fallback
  # order (WorkspaceProfile#resolve); the backend is the code that drives one
  # (Harbor::Runtimes::Backend). A host extends it in a subclass named by
  # `config.runtime_class`.
  class Runtime < ApplicationRecord
    self.table_name = "runtimes"

    # A failed health check keeps the runtime out of new placements for this
    # long; a passing check clears it straight away.
    HEALTH_TTL = 10.minutes

    has_many :workspace_profile_runtimes, class_name: "Harbor::WorkspaceProfileRuntime", foreign_key: :runtime_id,
             dependent: :restrict_with_error
    has_many :workspace_profiles, through: :workspace_profile_runtimes
    has_many :runs, class_name: Harbor.class_name_for(:run_class), foreign_key: :runtime_id, dependent: :restrict_with_error

    validates :key, presence: true, uniqueness: true, format: { with: /\A[a-z0-9][a-z0-9-]*\z/ }
    validates :name, presence: true
    validate { errors.add(:backend, "is not a registered backend") unless Harbor::Runtimes.registered?(backend) }
    validates :max_concurrent, numericality: { only_integer: true, greater_than: 0 }
    validate { errors.add(:config, "must be a JSON object") unless config.is_a?(Hash) }

    scope :ordered, -> { order(:position, :id) }
    scope :enabled, -> { where(enabled: true) }

    def self.find_by_key!(key) = find_by!(key: key.to_s)

    def backend_class = Harbor::Runtimes.backend(backend)

    # A backend instance for this runtime; `options` go to its initializer.
    def adapter(**options) = backend_class.new(self, **options)

    # Why new work can't be placed here right now, or nil. Never touches the
    # network: a backend reports missing configuration or an unbuilt
    # integration, and a recent failed health check counts too.
    def unavailable_reason
      return "disabled" unless enabled?
      reason = adapter.unready_reason
      return reason if reason
      "unhealthy: #{last_error.to_s.truncate(120)}" if recently_failed?
    end

    def healthy? = adapter.unready_reason.nil? && !recently_failed?

    # A live probe (the "Check" button). Records the result either way.
    def check_health!
      adapter.health_check
      update!(checked_at: Time.current, last_error: nil)
      true
    rescue StandardError => e
      update!(checked_at: Time.current, last_error: "#{e.class.name.demodulize}: #{e.message}".truncate(500))
      false
    end

    def busy = Harbor::Runtimes::Slots.busy(self)
    def free = [ max_concurrent - busy, 0 ].max
    def full? = free.zero?
    def usage_label = "#{busy}/#{max_concurrent} busy"

    private

    def recently_failed? = last_error.present? && checked_at.present? && checked_at > HEALTH_TTL.ago
  end
end
