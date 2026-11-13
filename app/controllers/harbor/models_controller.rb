module Harbor
  # Models: the providers with their usage and switches, and the aliases
  # agents are given, as two tabs.
  class ModelsController < ApplicationController
    harbor_page :models

    def index
      @tab = params[:tab] == "aliases" ? :aliases : :models
      if @tab == :aliases
        @aliases = Harbor.model_alias_class.includes(model_choices: :model_provider).order(:name)
      else
        @providers = Harbor::ModelProvider.order(:key)
      end
    end

    # Reading usage is the host's (it knows where the logins are): this asks
    # it to, through `config.refresh_model_usage`.
    def refresh
      refresher = Harbor.config.refresh_model_usage or return head(:not_found)
      user = respond_to?(:current_user, true) ? send(:current_user) : nil
      run = refresher.call(user)
      redirect_to models_path, notice: run.respond_to?(:id) ? "Refreshing usage. Follow progress in run ##{run.id}." : "Refreshing usage."
    end
  end
end
