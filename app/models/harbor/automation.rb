require "fugit"

module Harbor
  # An automation is one thing a site does on its own: a row a person can
  # read, switch off, reschedule and run by hand.
  #
  #   kind: agent   an agent plus instructions (or a slash command). Made and
  #                 edited on the Automations page, with no deploy.
  #   kind: job     one of the site's own job classes. Made in code (a seed);
  #                 the page edits only its words, schedule and switch.
  #
  #   trigger_kind: schedule   a cron, fired by the tick (Harbor::Automations::Tick)
  #                 manual     only "Run now"
  #                 …          a trigger the host declared and fires itself
  #                            (Harbor::Automations.trigger)
  #
  # Every firing is a tracked run (`runs.automation_id`), started by
  # Harbor::Automations::Dispatch.
  #
  # A host with more on its automations subclasses the record and names it:
  # `c.automation_class = "Automation"`.
  class Automation < ApplicationRecord
    self.table_name = "automations"

    KINDS = Harbor::Automations::KINDS
    # How a job automation is started (Harbor::Automations::Dispatch):
    #   loader, skill   Harbor makes the run, named by the automation's key in
    #                   that column of the run, and enqueues the job with its id
    #   self            the job makes its own run; Harbor only asks it to start
    JOB_DISPATCH = %w[loader skill self].freeze

    belongs_to :agent, class_name: Harbor.class_name_for(:agent_class), foreign_key: :agent_key, primary_key: :key, optional: true
    has_many :runs, class_name: Harbor.class_name_for(:run_class), foreign_key: :automation_id, dependent: :nullify,
                    inverse_of: :automation

    include Harbor::KeyFromName

    validates :key, presence: true, uniqueness: true, format: { with: /\A[a-z0-9][a-z0-9-]*\z/ }
    validates :name, presence: true
    validates :kind, inclusion: { in: KINDS }
    validates :job_dispatch, inclusion: { in: JOB_DISPATCH }
    validates :category, inclusion: { in: ->(_) { Harbor::Automations.categories.map(&:key) } },
                         if: -> { Harbor::Automations.categories.any? }
    validates :trigger_kind, inclusion: { in: ->(_) { Harbor::Automations.trigger_kinds } }
    # A job automation made in code needn't name a folder; one that does, and
    # every agent automation, names a declared one.
    validates :cwd_key, inclusion: { in: ->(_) { Harbor::Automations.working_folders.map(&:key) } },
                        if: -> { Harbor::Automations.working_folders.any? && (agent? || !cwd_key.nil?) }
    validates :timeout_ms, numericality: { only_integer: true, greater_than: 0 }
    validate :validate_kind, :validate_trigger

    # A schedule starts counting from when it was set (or switched back on),
    # never from the cron's previous occurrence: a row made at 10:00 with
    # "0 8 * * *" fires tomorrow at 08:00, not on the next tick.
    before_save :stamp_schedule_marker

    scope :enabled, -> { where(enabled: true) }
    scope :scheduled, -> { where(trigger_kind: "schedule") }
    # As the page lists them: by category in the order declared, then by
    # position and name.
    scope :ordered, lambda {
      keys = Harbor::Automations.categories.map(&:key)
      next order(:position, :name) if keys.empty?
      order(Arel.sql(sanitize_sql_array([ "array_position(ARRAY[?]::text[], automations.category::text)", keys ])), :position, :name)
    }

    def self.id_for(key) = where(key:).pick(:id)

    # The agents the form offers for an agent automation. A host whose
    # automations need a particular kind of agent narrows this in its subclass.
    def self.offered_agents = Harbor.agent_class.enabled.order(:key)

    # What a new automation starts with on the page, beyond being an agent
    # automation started by hand. A host's subclass adds its own.
    def self.page_defaults = { category: Harbor::Automations.categories.first&.key }.compact

    # What the form says when asked to run an automation as an identity the
    # site didn't declare.
    def self.identity_refusal = "is not an identity this site declared"

    def job? = kind == "job"
    def agent? = kind == "agent"
    def scheduled? = trigger_kind == "schedule"
    def manual? = trigger_kind == "manual"

    def job_klass = job_class.presence&.constantize

    # The working folder, when one is named and declared.
    def cwd = Harbor::Automations.find_working_folder(cwd_key)&.location
    def cwd_label = Harbor::Automations.find_working_folder(cwd_key)&.label

    # How the identity it runs as reads on a page.
    def run_as_label = run_as.presence && (Harbor::Automations.find_identity(run_as)&.label || run_as)

    def parsed_cron = cron.present? ? Fugit.parse_cron(cron) : nil

    # Fugit works a cron out in the process's time zone, the clock the tick
    # runs on, so "next in 3 hours" is right whatever zone the page shows.
    def next_run_at = scheduled? ? parsed_cron&.next_time&.to_t : nil

    # The cron tick this automation most recently became due for.
    def due_at(now = Time.current) = parsed_cron&.previous_time(now)&.to_t

    # The zone crons are read in, as a person names it ("America/Denver").
    def self.schedule_zone = EtOrbi.determine_local_tzone&.name

    def last_run = runs.recent.first
    def in_flight = runs.queued_or_running.order(:id).first

    # What starts it, as data: a list of hashes shaped like a workflow's
    # triggers, which Overview asks each stage about (`starts_on`). Harbor's
    # own triggers have a kind and nothing more; a host whose trigger says
    # more (which event, on what) returns that in its subclass.
    def trigger_data = [ { "kind" => trigger_kind } ]

    # What starts it, in words, for the list's Trigger column.
    def trigger_summary
      case trigger_kind
      when "schedule" then self.class.describe_cron(cron)
      when "manual" then "manual"
      else Harbor::Automations.find_trigger(trigger_kind)&.label || trigger_kind.to_s
      end
    end

    # "daily at 08:20", "weekly on Sat at 03:00", "every 15 min", else the cron.
    def self.describe_cron(cron)
      m, h, dom, mon, dow = cron.to_s.split
      return cron.to_s unless dow && dom == "*" && mon == "*"
      time = ->(hh, mm) { format("%02d:%02d", hh.to_i, mm.to_i) }
      days = %w[Sun Mon Tue Wed Thu Fri Sat]
      if m =~ /\A\*\/(\d+)\z/ && h == "*" then "every #{$1} min"
      elsif m =~ /\A\d+\z/ && h =~ /\A\*\/(\d+)\z/ then "every #{$1} h at :#{format('%02d', m.to_i)}"
      elsif m =~ /\A\d+\z/ && h == "*" then "hourly at :#{format('%02d', m.to_i)}"
      elsif m =~ /\A\d+\z/ && h =~ /\A\d+\z/ && dow == "*" then "daily at #{time.call(h, m)}"
      elsif m =~ /\A\d+\z/ && h =~ /\A\d+\z/ && dow =~ /\A[0-6]\z/ then "weekly on #{days[dow.to_i]} at #{time.call(h, m)}"
      else cron.to_s
      end
    end

    private

    def stamp_schedule_marker
      return unless scheduled?
      fresh = new_record? ? last_scheduled_at.nil? : (trigger_kind_changed? || cron_changed? || (enabled_changed? && enabled?))
      self.last_scheduled_at = Time.current if fresh
    end

    def validate_kind
      if job?
        errors.add(:job_class, "can't be blank") if job_class.blank?
        begin
          job_klass
        rescue NameError
          errors.add(:job_class, "is not a job class in this app")
        end
      else
        errors.add(:agent_key, "must name an agent") if agent_key.blank?
        if prompt.blank? == slash_command.blank?
          errors.add(:base, "Give either instructions or a slash command, not both")
        end
        identities = Harbor::Automations.identities.map(&:key)
        errors.add(:run_as, self.class.identity_refusal) if identities.any? && !identities.include?(run_as)
      end
    end

    def validate_trigger
      errors.add(:cron, "is not a valid cron expression") if scheduled? && parsed_cron.nil?
    end
  end
end
