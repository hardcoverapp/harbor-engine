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
      @choices = Harbor::Runtimes.choices
      @runtime = Harbor.runtime_class.new(backend: @choices.first&.backend, max_concurrent: 2, enabled: true, position: next_position)
      @choice = @choices.find { |choice| choice.value == params[:type] } || @choices.first
    end

    # A new place for work to run. It takes no work until a workspace lists
    # it, so adding one changes nothing by itself.
    def create
      @choices = Harbor::Runtimes.choices
      @runtime = Harbor.runtime_class.new(position: next_position)
      if assign_form(@runtime) && @runtime.save
        redirect_to runtimes_path, notice: "#{@runtime.name} added. It takes work once a workspace lists it."
      else
        render :new, status: :unprocessable_entity
      end
    end

    def edit
      @runtime = Harbor.runtime_class.find(params[:id])
      @choices = Harbor::Runtimes.choices_for(@runtime.backend)
      @choice = @choices.find { |choice| choice.value == @runtime.adapter.choice_value } || @choices.first
    end

    # Only a runtime nothing depends on: one in no workspace, with no runs.
    def destroy
      runtime = Harbor.runtime_class.find(params[:id])
      if runtime.destroy
        redirect_to runtimes_path, notice: "#{runtime.name} removed."
      else
        redirect_to edit_runtime_path(runtime), alert: "#{runtime.name} can't be removed: #{runtime.errors.full_messages.to_sentence.presence || 'a workspace lists it or runs used it'}. Switch it off instead."
      end
    end

    # Either the whole form (the edit page), or a few values by themselves:
    # the list's Enable and Disable buttons send only `enabled`.
    def update
      @runtime = Harbor.runtime_class.find(params[:id])
      return update_from_form if params[:runtime].key?(:type)

      attrs = params.require(:runtime).permit(:enabled, :max_concurrent, :name, :host).to_h
      if params[:runtime].key?(:config)
        attrs["config"] = Harbor::Runtimes.parse_config(params[:runtime][:config])
      end
      if @runtime.update(attrs)
        Harbor.availability_changed!
        redirect_to runtimes_path, notice: saved_notice
      else
        redirect_to runtimes_path, alert: @runtime.errors.full_messages.to_sentence
      end
    rescue ArgumentError => e
      redirect_to runtimes_path, alert: e.message
    end

    def check
      runtime = Harbor.runtime_class.find(params[:id])
      back = params[:from] == "edit" ? edit_runtime_path(runtime) : runtimes_path
      if runtime.check_health!
        Harbor.availability_changed!
        redirect_to back, notice: "#{runtime.name} is healthy."
      else
        redirect_to back, alert: "#{runtime.name} failed its health check: #{runtime.last_error}"
      end
    end

    private

    def next_position = Harbor.runtime_class.maximum(:position).to_i + 1

    def saved_notice = "#{@runtime.name} #{@runtime.enabled? ? 'enabled' : 'disabled'} · #{@runtime.max_concurrent} at once. Applies to new workspaces."

    def update_from_form
      @choices = Harbor::Runtimes.choices_for(@runtime.backend)
      if assign_form(@runtime) && @runtime.save
        Harbor.availability_changed!
        redirect_to runtimes_path, notice: saved_notice
      else
        render :edit, status: :unprocessable_entity
      end
    end

    # Puts the form's values on `runtime`. The form sends the kind of runtime
    # chosen (`type`) and, under `fields`, that kind's own values; its backend
    # turns those into the runtime's config. False, with the reason among the
    # runtime's errors, when they can't be used.
    def assign_form(runtime)
      form = params.require(:runtime)
      runtime.assign_attributes(form.permit(:name, :max_concurrent, :enabled))
      @choice = @choices.find { |choice| choice.value == form[:type] }
      if @choice.nil?
        runtime.errors.add(:base, "Choose what kind of runtime this is.")
        @choice = @choices.first
        return false
      end
      runtime.backend = @choice.backend
      fields = form.dig(:fields, @choice.value)&.permit!&.to_h&.with_indifferent_access || {}.with_indifferent_access
      @fields = fields
      runtime.assign_attributes(@choice.backend_class.settings_from(fields, choice: @choice))
      true
    rescue ArgumentError => e
      runtime.errors.add(:base, e.message)
      false
    end
  end
end
