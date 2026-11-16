module Harbor
  # The accounts agents act as (Harbor::Identity): made, edited and deleted
  # here, and listed on the Agents page's Identities tab. Part of the Agents
  # page, so it follows that page's switch.
  class IdentitiesController < ApplicationController
    harbor_page :agents
    before_action :set_identity, only: %i[edit update destroy]

    def new = @identity = Harbor::Identity.new
    def edit; end

    def create
      @identity = Harbor::Identity.new
      save(:new, "Identity saved. Give it to an agent on the agent's form.")
    end

    def update = save(:edit, "Identity saved. New runs use it.")

    def destroy
      if @identity.destroy
        redirect_to agents_path(tab: "identities"), notice: "#{@identity.name} deleted."
      else
        redirect_to agents_path(tab: "identities"), alert: @identity.errors.full_messages.to_sentence
      end
    end

    private

    def set_identity = @identity = Harbor::Identity.find(params[:id])

    def save(template, notice)
      if @identity.update(params.require(:identity).permit(:name, :kind, :login, :token_env))
        redirect_to agents_path(tab: "identities"), notice: notice
      else
        render template, status: :unprocessable_entity
      end
    end
  end
end
