module Harbor
  # Harbor's pages inherit the host's base controller: its login check, layout
  # and current user (`Harbor.config.parent_controller`).
  class ApplicationController < Harbor.config.parent_controller.constantize
    include Harbor::PageGate
    helper Harbor::HostRoutesHelper
    helper Harbor::ModelsHelper

    private
      # The host's current user, when its controller has one.
      def harbor_current_user = respond_to?(:current_user, true) ? send(:current_user) : nil

      def harbor_user_label
        user = harbor_current_user
        user && Harbor.config.user_label.call(user)
      end
  end
end
