class Users::OmniauthCallbacksController < Devise::OmniauthCallbacksController
  skip_before_filter :verify_authenticity_token, :only => [:developer]
  def github
    @user = User.find_for_github_oauth(request.env["omniauth.auth"], current_user)

    sign_in_and_redirect @user, :event => :authentication #this will throw if @user is not activated
    flash[:notice] = "Nice person you are. Welcome!"
  end

  def developer
    @user = User.where(admin: true).first
    sign_in_and_redirect @user, :event => :authentication #this will throw if @user is not activated
    flash[:notice] = "Nice person you are. Welcome!"
  end
end
