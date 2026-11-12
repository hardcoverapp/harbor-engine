module Harbor
  # Harbor's pages render inside the host's layout, which links to the host's
  # own pages by route helper. Inside an engine those helpers aren't defined,
  # so pass them on to the host's routes.
  module HostRoutesHelper
    def method_missing(name, *args, **kwargs, &block)
      return super unless host_route?(name)
      main_app.public_send(name, *args, **kwargs, &block)
    end

    def respond_to_missing?(name, include_private = false)
      host_route?(name) || super
    end

    private
      def host_route?(name)
        name.to_s.end_with?("_path", "_url") && main_app.respond_to?(name)
      end
  end
end
