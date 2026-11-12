module Harbor
  # What came in over webhooks and what was done with each delivery. Receiving
  # them is the host's, at an endpoint of its own with no login.
  class WebhooksController < ApplicationController
    harbor_page :webhooks

    def index
      @events = Harbor.webhook_event_class.for_page.limit(100)
    end
  end
end
