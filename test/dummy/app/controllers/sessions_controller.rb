class SessionsController < ApplicationController
  skip_before_action :require_login

  def new = render(plain: "Log in")

  def create
    session[:user_name] = params[:name]
    redirect_to root_path
  end

  def destroy
    reset_session
    redirect_to login_path
  end
end
