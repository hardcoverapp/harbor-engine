require "erb"
require "yaml"
require "pathname"

module Harbor
  # The host's one Harbor config file: `config/harbor.yml`, or wherever
  # `Harbor.config.config_file` says. It is run through ERB and then read as
  # YAML, like `config/database.yml`. Secrets never go in it: an entry names
  # the ENV key that holds one.
  #
  # A missing file declares nothing. Anything else wrong with it is an Error
  # naming the file, raised every time the file is read, so a mistake is never
  # quietly treated as "nothing declared".
  #
  # The file is read each time it is asked for, and parsed again only when its
  # text (after ERB) has changed, so an ENV key the ERB reads is honoured the
  # way a `declare_each_time` block always was.
  #
  # To give the file a new top-level section, add its name to SECTIONS and read
  # it with `ConfigFile.section("name")`.
  module ConfigFile
    Error = Class.new(StandardError)

    SECTIONS = %w[databases restore_environments].freeze

    class << self
      def path
        value = Harbor.config.config_file
        value = value.call if value.respond_to?(:call)
        Pathname(value.to_s)
      end

      # The file as it reads in a message: from the app's root when inside it.
      def label
        path = self.path
        root = "#{Rails.root}/"
        path.to_s.start_with?(root) ? path.to_s.delete_prefix(root) : path.to_s
      end

      def exist? = path.file?

      # One top-level section, as a Hash with string keys ({} when the file or
      # the section is absent).
      def section(name)
        name = name.to_s
        raise ArgumentError, "Unknown config section #{name}" unless SECTIONS.include?(name)
        value = sections[name]
        return {} if value.nil?
        raise Error, "#{label}: #{name} must be a mapping" unless value.is_a?(Hash)
        value
      end

      # Every section. The same object is returned until the file's text
      # changes, so a caller can tell cheaply whether to parse again.
      def sections
        path = self.path
        return forget && {} unless path.file?
        text = render(path)
        key = [ path.to_s, text ]
        # One assignment, so another thread never sees a key without its value.
        cached = @cache
        return cached.last if cached && cached.first == key
        parsed = parse(text)
        @cache = [ key, parsed ]
        parsed
      end

      # Forget what was read (tests, and a host that rewrites the file).
      def reload!
        forget
        nil
      end

      private
        def forget
          @cache = nil
          true
        end

        def render(path)
          ERB.new(path.read, trim_mode: "-").result
        rescue StandardError, ScriptError => error
          raise Error, "#{label}: #{error.message}"
        end

        def parse(text)
          refuse_repeated_keys(YAML.parse(text))
          data = YAML.safe_load(text, aliases: true)
          return {}.freeze if data.nil?
          raise Error, "#{label}: must be a mapping of sections (#{SECTIONS.join(', ')})" unless data.is_a?(Hash)
          data = data.transform_keys(&:to_s)
          unknown = data.keys - SECTIONS
          raise Error, "#{label}: unknown section #{unknown.join(', ')} (expected #{SECTIONS.join(', ')})" if unknown.any?
          data.freeze
        rescue Psych::Exception => error
          raise Error, "#{label}: not valid YAML: #{error.message}"
        end

        # YAML keeps the last of two entries with the same key and says
        # nothing. Here that would quietly drop a database or an environment.
        def refuse_repeated_keys(node, trail = [])
          return unless node
          if node.is_a?(Psych::Nodes::Mapping)
            pairs = node.children.each_slice(2).to_a
            names = pairs.map { |key, _| key.respond_to?(:value) ? key.value.to_s : nil }.compact
            repeated = names.detect { |name| names.count(name) > 1 }
            raise Error, "#{label}: #{[ *trail, repeated ].join('.')} appears twice" if repeated
            pairs.each { |key, value| refuse_repeated_keys(value, [ *trail, key.respond_to?(:value) ? key.value : "?" ]) }
          else
            Array(node.children).each { |child| refuse_repeated_keys(child, trail) }
          end
        end
    end
  end
end
