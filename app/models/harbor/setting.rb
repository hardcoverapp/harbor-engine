module Harbor
  # A value saved on the Settings page for one declared setting
  # (Harbor::Settings). Read settings with `Harbor::Setting.get(:key)`.
  class Setting < ApplicationRecord
    EXPORT_PATH = "harbor/settings.json".freeze

    # Where a value came from, for the page.
    Resolved = Struct.new(:definition, :value, :source, :env_key, :record, keyword_init: true)

    validates :key, presence: true, uniqueness: true
    validate :key_is_declared

    after_commit { self.class.export! }

    class << self
      def get(key) = resolve(key).value

      # Saved value, else the host's ENV fallback, else the default. An ENV
      # value that isn't the setting's type is ignored, with a log line.
      def resolve(key, record: :lookup)
        definition = Settings.find(key)
        record = saved(definition.key) if record == :lookup
        return Resolved.new(definition:, value: record.value, source: :saved, record:) if record

        env_key = Harbor.config.env_fallbacks[definition.key]
        raw = env_key && ENV[env_key]
        if raw.present?
          begin
            return Resolved.new(definition:, value: definition.cast(raw), source: :env, env_key:)
          rescue ArgumentError => e
            Rails.logger.warn("[harbor] ignoring #{env_key}=#{raw.inspect}: #{e.message}")
          end
        end
        Resolved.new(definition:, value: definition.default, source: :default, env_key:)
      end

      # Every declared setting, resolved with one query.
      def resolve_all
        records = where(key: Settings.all.map(&:key)).index_by(&:key)
        Settings.all.map { |definition| resolve(definition.key, record: records[definition.key]) }
      end

      # Raises ArgumentError when `raw` isn't the setting's type.
      def set!(key, raw, by: nil)
        definition = Settings.find(key)
        record = find_or_initialize_by(key: definition.key)
        record.update!(value: definition.cast(raw), updated_by: by)
        record
      end

      # Back to the ENV fallback or default.
      def reset!(key)
        where(key: Settings.find(key).key).destroy_all
      end

      # The saved values, handed to the host to keep outside the database.
      def export!
        hook = Harbor.config.export or return
        saved = where(key: Settings.all.map(&:key)).order(:key).to_h { |record| [ record.key, record.value ] }
        hook.call(EXPORT_PATH, JSON.pretty_generate(saved) + "\n")
      rescue => e
        Rails.logger.error("[harbor] settings export failed: #{e.class}: #{e.message}")
      end

      private
        def saved(key) = find_by(key: key)
    end

    private
      def key_is_declared
        errors.add(:key, "is not a declared setting") unless Settings.declared?(key)
      end
  end
end
