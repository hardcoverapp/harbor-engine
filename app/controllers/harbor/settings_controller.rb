module Harbor
  # The Settings page: every declared setting, its value and where the value
  # comes from. Saving takes effect at once, with no deploy or restart.
  class SettingsController < ApplicationController
    before_action :set_definition, only: %i[update destroy]

    def index
      @groups = Setting.resolve_all.group_by { |resolved| resolved.definition.group }
    end

    def update
      Setting.set!(@definition.key, params[:value], by: harbor_user_label)
      redirect_to settings_path, notice: "Saved #{@definition.label}."
    rescue ArgumentError => e
      redirect_to settings_path, alert: e.message
    end

    # Forget the saved value: back to the ENV fallback or the default.
    def destroy
      Setting.reset!(@definition.key)
      redirect_to settings_path, notice: "#{@definition.label} is back to its default."
    end

    private
      def set_definition
        @definition = Settings.find(params[:key])
      rescue Settings::Unknown
        raise ActiveRecord::RecordNotFound
      end
  end
end
