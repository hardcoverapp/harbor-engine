# Harbor's pages. Each area's routes move here with its controllers; the rest
# still live in the host.
Harbor::Engine.routes.draw do
  resources :settings, only: %i[index update destroy], param: :key
  resources :webhooks, only: :index
end
