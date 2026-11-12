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

      # Tests only.
      def unregister(name) = backends.delete(name.to_s)

      private
        def backends = (@backends ||= {})
    end
  end
end
