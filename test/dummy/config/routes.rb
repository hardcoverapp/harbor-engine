Rails.application.routes.draw do
  # The host's own pages and login.
  root "pages#home"
  get "login" => "sessions#new", as: :login
  post "login" => "sessions#create"
  delete "logout" => "sessions#destroy", as: :logout
  get "reports" => "pages#reports", as: :reports

  # The pages Harbor's menu links to while they still live in a host.
  %w[factory velocity automations workflows reviews runs agents models runtimes scorers webhooks].each do |page|
    get page => "pages#placeholder", as: page.to_sym
  end
  get "workspaces" => "pages#placeholder", as: :workspace_profiles
  get "proposals" => "pages#placeholder", as: :improvement_proposals

  mount Harbor::Engine => "/", as: :harbor
end
