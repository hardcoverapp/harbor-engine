module Harbor
  # A provider's switch on the Models page.
  class ModelProvidersController < ApplicationController
    harbor_page :models

    def update
      provider = Harbor::ModelProvider.find(params[:id])
      provider.update!(params.require(:model_provider).permit(:enabled))
      Harbor.availability_changed!
      redirect_to models_path, notice: "#{provider.display_name} #{provider.enabled? ? 'enabled' : 'disabled'} for queued and future runs."
    end
  end
end
