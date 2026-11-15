module Harbor
  # Velocity: how much work ran over a range, how it ended and what it cost
  # (Harbor::Velocity). The tab and the range are plain query params, and
  # everything is drawn on the server.
  class VelocityController < ApplicationController
    harbor_page :velocity
    helper Harbor::VelocityHelper
    helper Harbor::RunsHelper

    def show
      @range  = Harbor::Velocity::RANGES.key?(params[:range]) ? params[:range] : Harbor::Velocity::DEFAULT_RANGE
      @tabs   = Harbor::Velocity.tabs
      @tab    = @tabs.find { |tab| tab.key == params[:tab] } || @tabs.first
      @since  = Harbor::Velocity::RANGES[@range][1].ago.beginning_of_day
      @period = Harbor::Velocity::Period.new(since: @since)
    end
  end
end
