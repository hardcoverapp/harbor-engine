module Harbor
  # The places work can run, with their limits, live busy counts and health.
  # Switching one off here moves new work to the next runtime in each
  # workspace's list, with no deploy.
  class RuntimesController < ApplicationController
    harbor_page :runtimes

    def index
      @runtimes = Harbor.runtime_class.ordered.includes(:workspace_profiles)
    end

    def update
      runtime = Harbor.runtime_class.find(params[:id])
      attrs = params.require(:runtime).permit(:enabled, :max_concurrent, :name, :host).to_h
      if params[:runtime].key?(:config)
        attrs["config"] = JSON.parse(params[:runtime][:config].presence || "{}")
        raise ArgumentError, "Config must be a JSON object." unless attrs["config"].is_a?(Hash)
      end
      if runtime.update(attrs)
        Harbor.availability_changed!
        redirect_to runtimes_path, notice: "#{runtime.name} #{runtime.enabled? ? 'enabled' : 'disabled'} · #{runtime.max_concurrent} at once. Applies to new workspaces."
      else
        redirect_to runtimes_path, alert: runtime.errors.full_messages.to_sentence
      end
    rescue JSON::ParserError, ArgumentError => e
      redirect_to runtimes_path, alert: e.message
    end

    def check
      runtime = Harbor.runtime_class.find(params[:id])
      if runtime.check_health!
        Harbor.availability_changed!
        redirect_to runtimes_path, notice: "#{runtime.name} is healthy."
      else
        redirect_to runtimes_path, alert: "#{runtime.name} failed its health check: #{runtime.last_error}"
      end
    end
  end
end
