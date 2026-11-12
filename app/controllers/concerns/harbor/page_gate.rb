module Harbor
  # Makes a controller part of a page the site can switch off (Harbor::Pages).
  # While the page is off its actions answer as not found.
  #
  #   class ReportsController < ApplicationController
  #     include Harbor::PageGate
  #     harbor_page :reports
  #   end
  #
  # The check runs after the callbacks already declared, so put it below the
  # host's login check: someone who isn't logged in is sent to log in, not
  # told whether the page exists.
  module PageGate
    extend ActiveSupport::Concern

    class_methods do
      def harbor_page(page, **options)
        before_action(**options) do
          raise ActionController::RoutingError, "Not Found" unless Harbor::Pages.enabled?(page)
        end
      end
    end
  end
end
