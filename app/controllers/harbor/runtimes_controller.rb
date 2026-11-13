module Harbor
  # The places work can run, with their limits, live busy counts and health.
  # Switching one off here moves new work to the next runtime in each
  # workspace's list, with no deploy.
  class RuntimesController < ApplicationController
    harbor_page :runtimes

    def index
      @runtimes = Harbor.runtime_class.ordered.includes(:workspace_profiles)
    end

    def new
      @runtime = Harbor.runtime_class.new(backend: params[:backend].presence || Harbor::Runtimes.backend_names.first,
                                          max_concurrent: 2, position: next_position)
    end

    # A new place for work to run. It takes no work until a workspace lists
    # it, so adding one changes nothing by itself.
    def create
      attrs = params.require(:runtime).permit(:key, :name, :backend, :host, :max_concurrent, :enabled).to_h
      attrs["config"] = JSON.parse(params[:runtime][:config].presence || "{}")
      raise ArgumentError, "Config must be a JSON object." unless attrs["config"].is_a?(Hash)
      attrs["key"] = attrs["name"].to_s.parameterize if attrs["key"].blank?
      @runtime = Harbor.runtime_class.new(attrs.merge(position: next_position))
      if @runtime.save
        redirect_to runtimes_path, notice: "#{@runtime.name} added. It takes work once a workspace lists it."
      else
        render :new, status: :unprocessable_entity
      end
    rescue JSON::ParserError, ArgumentError => e
      @runtime = Harbor.runtime_class.new(attrs.to_h.except("config").merge(position: next_position))
      @runtime.errors.add(:base, e.is_a?(JSON::ParserError) ? "Config must be valid JSON." : e.message)
      render :new, status: :unprocessable_entity
    end

    # Only a runtime nothing depends on: one in no workspace, with no runs.
    def destroy
      runtime = Harbor.runtime_class.find(params[:id])
      if runtime.destroy
        redirect_to runtimes_path, notice: "#{runtime.name} removed."
      else
        redirect_to runtimes_path, alert: "#{runtime.name} can't be removed: #{runtime.errors.full_messages.to_sentence.presence || 'a workspace lists it or runs used it'}. Switch it off instead."
      end
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

    private

    def next_position = Harbor.runtime_class.maximum(:position).to_i + 1
  end
end
