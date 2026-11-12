module Harbor
  # Harbor's pages inherit the host's base controller: its login check, layout
  # and current user (`Harbor.config.parent_controller`).
  class ApplicationController < Harbor.config.parent_controller.constantize
    include Harbor::PageGate
    helper Harbor::HostRoutesHelper

    private
      def harbor_user_label
        user = respond_to?(:current_user, true) ? send(:current_user) : nil
        user && Harbor.config.user_label.call(user)
      end
  end
end
