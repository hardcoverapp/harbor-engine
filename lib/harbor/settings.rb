module Harbor
  # The declared settings: everything about a site that is data, edited on the
  # Settings page instead of in ENV or a constant. A setting has to be declared
  # here (key, type, default, description) before it can be read or saved.
  #
  # Reading one: `Harbor::Setting.get(:key)`. A value saved on the page wins;
  # until then the ENV key the host named for it applies (so moving a key off
  # ENV changes nothing on the day it deploys); then the default.
  module Settings
    TYPES = %i[boolean integer string].freeze

    Definition = Struct.new(:key, :type, :default, :group, :label, :description, :min, :max, keyword_init: true) do
      # A form or ENV string as this setting's type. Raises ArgumentError when
      # it isn't one, so a typo is refused instead of saved as something else.
      def cast(raw)
        case type
        when :boolean
          value = raw.to_s.strip.downcase
          return true if %w[true 1 on yes].include?(value)
          return false if %w[false 0 off no].include?(value)
          raise ArgumentError, "#{label} must be on or off"
        when :integer
          number = Integer(raw.to_s.strip, 10, exception: false) or raise ArgumentError, "#{label} must be a whole number"
          raise ArgumentError, "#{label} must be at least #{min}" if min && number < min
          raise ArgumentError, "#{label} must be at most #{max}" if max && number > max
          number
        else
          raw.to_s.strip
        end
      end
    end

    class Unknown < KeyError; end

    class << self
      def declare(key, type:, default:, group:, label:, description:, min: nil, max: nil)
        key = key.to_s
        raise ArgumentError, "unknown setting type #{type.inspect}" unless TYPES.include?(type)
        raise ArgumentError, "setting #{key} is already declared" if definitions.key?(key)

        definitions[key] = Definition.new(key:, type:, default:, group:, label:, description:, min:, max:)
      end

      def find(key)
        definitions.fetch(key.to_s) { raise Unknown, "no setting named #{key}" }
      end

      def declared?(key) = definitions.key?(key.to_s)

      def all = definitions.values

      def grouped = all.group_by(&:group)

      private
        def definitions = (@definitions ||= {})
    end
  end
end

require "harbor/settings/declarations"
