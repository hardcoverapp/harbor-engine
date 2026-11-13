# Harbor's pages. Each area's routes move here with its controllers; the rest
# still live in the host.
Harbor::Engine.routes.draw do
  # Every page sits under Harbor.path ("/factory" unless the config file's
  # `path:` says otherwise), so the section's addresses are its own.
  scope path: Harbor.path.presence do
    resources :settings, only: %i[index update destroy], param: :key
    resources :webhooks, only: :index

    # Models: providers and their usage, and the aliases agents are given.
    resources :models, only: :index do
      collection { post :refresh }
    end
    resources :model_aliases, except: %i[index show]
    resources :model_providers, only: :update

    # Where work runs: runtimes (places with limits) and workspaces (ordered
    # fallback lists of runtimes that agents pick).
    resources :runtimes, only: %i[index update] do
      member { post :check }
    end
    resources :workspace_profiles, path: "workspaces", except: %i[show]

    # Databases: the declared databases with their backups, and the backup and
    # restore runs.
    resources :databases, only: :index do
      collection do
        post :backup_all
        post "environments/:environment/restore", action: :restore_environment, as: :restore_environment
      end
      member do
        post :backup
        post :restore
      end
    end
  end

  # What runners post to, with a run's token and no login. A site behind a
  # firewall lets POSTs under /harbor/runner/ through, so every route here is
  # a POST, the one that fetches a file included. Not under Harbor.path:
  # runners and firewall rules are given this address, so it never moves.
  scope "harbor/runner", module: :runner, as: :runner do
    post "runs/:id/log", to: "runs#log", as: :run_log
    post "runs/:id/result", to: "runs#result", as: :run_result
    post "runs/:id/bundle/:name", to: "runs#bundle", as: :run_bundle, format: false
  end
end
