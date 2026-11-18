Rails.application.routes.draw do
  # The host's own pages and login.
  # (A test of a site with no home page of its own switches this off; the
  # layout's link home then goes to "/" all the same.)
  if Rails.configuration.x.harbor_dummy_no_home == true
    direct(:root) { "/" }
  else
    root "pages#home"
  end
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
