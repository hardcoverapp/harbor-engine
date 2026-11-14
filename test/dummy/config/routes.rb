Rails.application.routes.draw do
  # The host's own pages and login.
  root "pages#home"
  get "login" => "sessions#new", as: :login
  post "login" => "sessions#create"
  delete "logout" => "sessions#destroy", as: :logout
  get "reports" => "pages#reports", as: :reports

  # One of the pages Harbor's menu names that this host happens to have. The
  # rest of Harbor's entries that are still a host's have no route here, so
  # the menu leaves them out.
  get "workflows" => "pages#placeholder", as: :workflows

  mount Harbor::Engine => "/", as: :harbor
end
