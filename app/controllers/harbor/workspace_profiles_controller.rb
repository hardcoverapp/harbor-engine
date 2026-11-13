module Harbor
  # Workspaces: named, ordered fallback lists of runtimes. Agents pick one; a
  # run uses the first runtime that is switched on, healthy, below its limit
  # and able to run the agent's model.
  class WorkspaceProfilesController < ApplicationController
    harbor_page :workspaces
    before_action :set_profile, only: %i[edit update destroy]

    def index
      @profiles = Harbor.workspace_profile_class.includes(workspace_profile_runtimes: :runtime).order(:name)
      @agents_by_profile = Harbor.agent_class.where.not(workspace_profile_id: nil).order(:key).group_by(&:workspace_profile_id)
    end

    def new
      @workspace_profile = Harbor.workspace_profile_class.new
      @workspace_profile.workspace_profile_runtimes.build(position: 0)
    end

    def edit; end

    def create
      @workspace_profile = Harbor.workspace_profile_class.new(profile_params)
      if @workspace_profile.save
        redirect_to workspace_profiles_path, notice: "Workspace created."
      else
        render :new, status: :unprocessable_entity
      end
    end

    def update
      if @workspace_profile.update(profile_params)
        Harbor.availability_changed!
        redirect_to workspace_profiles_path, notice: "Workspace updated for queued and future runs."
      else
        render :edit, status: :unprocessable_entity
      end
    end

    def destroy
      if @workspace_profile.destroy
        redirect_to workspace_profiles_path, notice: "Workspace deleted."
      else
        redirect_to workspace_profiles_path, alert: "Move agents off this workspace before deleting it."
      end
    end

    private

    def set_profile = @workspace_profile = Harbor.workspace_profile_class.find(params[:id])

    def profile_params
      params.require(:workspace_profile).permit(:name, :key, :description,
        workspace_profile_runtimes_attributes: %i[id runtime_id position _destroy])
    end
  end
end
