# What a host brings: a login check, a current user and a layout.
class ApplicationController < ActionController::Base
  before_action :require_login
  helper_method :current_user

  User = Struct.new(:name, :email)

  private
    def current_user
      session[:user_name] && User.new(session[:user_name], "#{session[:user_name].parameterize}@example.com")
    end

    def require_login
      redirect_to main_app.login_path unless current_user
    end
end
