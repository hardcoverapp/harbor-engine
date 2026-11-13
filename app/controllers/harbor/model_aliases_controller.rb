module Harbor
  # Creating and editing model aliases: a name and its ordered list of models,
  # each picked from its provider's catalog (Harbor::ModelCatalog).
  class ModelAliasesController < ApplicationController
    harbor_page :models
    before_action :set_alias, only: %i[edit update destroy]

    def new
      @model_alias = Harbor.model_alias_class.new
      @model_alias.model_choices.build(cutoff_percent: 80)
      load_model_options
    end

    def edit
      load_model_options
    end

    def create
      @model_alias = Harbor.model_alias_class.new(alias_params)
      if @model_alias.save
        redirect_to models_path(tab: "aliases"), notice: "Model alias created."
      else
        load_model_options
        render :new, status: :unprocessable_entity
      end
    end

    def update
      if @model_alias.update(alias_params)
        Harbor.availability_changed!
        redirect_to models_path(tab: "aliases"), notice: "Model alias updated for queued and future runs."
      else
        load_model_options
        render :edit, status: :unprocessable_entity
      end
    end

    def destroy
      if @model_alias.destroy
        redirect_to models_path(tab: "aliases"), notice: "Model alias deleted."
      else
        redirect_to models_path(tab: "aliases"), alert: "Reassign whatever uses this alias before deleting it."
      end
    end

    private

    def set_alias = @model_alias = Harbor.model_alias_class.find(params[:id])

    # Each provider's models for the pickers. When the catalog can't be read,
    # the models already saved for that provider are offered instead, and a
    # choice's own saved model is always in its list.
    def load_model_options
      @model_providers = Harbor::ModelProvider.order(:key).to_a
      @model_options = {}
      @model_catalog_errors = []
      @model_providers.each do |provider|
        begin
          options = Harbor::ModelCatalog.fetch(provider).dup
        rescue Harbor::ModelCatalog::Unavailable => error
          @model_catalog_errors |= [ error.message ] # one catalog serves every provider
          options = provider.model_choices.distinct.order(:model).pluck(:model).map { |model| [ model, model ] }
        end
        @model_alias.model_choices.select { |choice| choice.model_provider_id == provider.id && choice.model.present? }.each do |choice|
          options << [ choice.model, choice.model ] unless options.any? { |_, id| id == choice.model }
        end
        @model_options[provider.id.to_s] = options
      end
    end

    def alias_params
      params.require(:model_alias).permit(:name, :description,
        model_choices_attributes: %i[id model_provider_id model effort position cutoff_percent _destroy])
    end
  end
end
