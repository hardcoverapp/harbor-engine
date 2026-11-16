module Harbor
  # Where work runs. A runtime row (Harbor::Runtime) names a backend: the code
  # that makes a workspace there and runs an agent in it. Backends are
  # registered by name, so a host adds its own:
  #
  #   Harbor::Runtimes.register "bridge", "Runtimes::Backends::Bridge"
  #
  # The class is named as a string and looked up when used, so registering in
  # an initializer doesn't load it early.
  module Runtimes
    class UnknownBackend < ArgumentError; end

    # One kind of runtime the form offers: `value` is what the form sends,
    # `backend` the registered backend behind it.
    Choice = Struct.new(:value, :backend, :label, :description, keyword_init: true) do
      def backend_class = Harbor::Runtimes.backend(backend)
    end

    class << self
      def register(name, class_name)
        backends[name.to_s] = class_name.to_s
      end

      def registered?(name) = backends.key?(name.to_s)

      def backend_names = backends.keys

      # The backend class registered under `name`.
      def backend(name)
        backends.fetch(name.to_s) { raise UnknownBackend, "unknown runtime backend #{name.inspect}" }.constantize
      end

      def backend_classes = backends.values.map(&:constantize)

      # What the "New runtime" page offers: every choice of every backend
      # that is offered.
      def choices
        backend_names.flat_map { |name| backend(name).offered? ? backend(name).choices(name) : [] }
      end

      # What the "New runtime" page says about the backends it doesn't offer.
      def unoffered_notes = backend_names.filter_map { |name| backend(name).offered? ? nil : backend(name).unoffered_note }

      # The choices of one backend, offered or not (to edit a runtime it has).
      def choices_for(name) = backend(name).choices(name.to_s)

      # A runtime's config as typed: a JSON object, or nothing. Raises
      # ArgumentError saying what is wrong.
      def parse_config(json)
        config = JSON.parse(json.presence || "{}")
        raise ArgumentError, "Config must be a JSON object." unless config.is_a?(Hash)
        config
      rescue JSON::ParserError
        raise ArgumentError, "Config must be valid JSON."
      end

      # Tests only.
      def unregister(name) = backends.delete(name.to_s)

      private
        def backends = (@backends ||= {})
    end
  end
end

# Harbor's own ways of running work. A host registers any others.
Harbor::Runtimes.register "orca", "Harbor::Runtimes::Backends::Orca"
Harbor::Runtimes.register "conductor_cloud", "Harbor::Runtimes::Backends::ConductorCloud"
Harbor::Runtimes.register "orca_per_workspace", "Harbor::Runtimes::Backends::OrcaPerWorkspace"
