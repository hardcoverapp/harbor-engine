# Harbor's pages. Each area's routes move here with its controllers; the rest
# still live in the host.
Harbor::Engine.routes.draw do
  # Every page sits under Harbor.path ("/factory" unless the config file's
  # `path:` says otherwise), so the section's addresses are its own.
  # Overview is the section's front page: the path itself. With the pages at
  # the root that is "/", and it answers at /overview too, which is where it
  # is found when the host has a home page of its own at "/".
  get Harbor.front_path, to: "overview#show", as: :overview
  get Harbor.front_page_also, to: "overview#show", as: :overview_also if Harbor.at_root?

  scope path: Harbor.path.presence do
    # A stage's note on Overview, edited in place.
    resources :stage_notes, path: "notes", param: :stage_key, only: %i[show edit update]

    # Velocity: runs, spending and scorers over a range.
    get "velocity", to: "velocity#show", as: :velocity

    resources :settings, only: %i[index update destroy], param: :key
    resources :webhooks, only: :index

    # Runs: the list, a run's page with its live log, the raw stream it kept,
    # and Stop. A host adds actions of its own under the same addresses in
    # its own routes (`resources :runs, only: [] do member { … } end`).
    resources :runs, only: %i[index show] do
      member do
        get :raw
        post :stop
        post :score
      end
    end

    # Automations: the list, the form that makes and edits one, the switch,
    # "Run now" and Delete.
    resources :automations, except: :show do
      member do
        post :run
        patch :toggle
      end
    end

    # Scorers: judges over finished agent runs, and their verdicts. Proposals:
    # the changes drafted from a scorer's repeated failures, applied or
    # dismissed by a person. A run is judged by hand with a POST to
    # runs/<id>/score.
    resources :scorers, except: :destroy do
      member { patch :toggle }
    end
    resources :proposals, only: %i[index show] do
      member do
        post :apply
        post :dismiss
      end
      collection { post :check }
    end

    # Review policy: the rules (every save a version, with roll back and a
    # preview where the host has one), a round with its checks, and the
    # dashboard.
    get "reviews", to: "reviews#index", as: :reviews
    scope "reviews" do
      get "dashboard", to: "review_dashboards#show", as: :review_dashboard
      resources :rounds, controller: "review_rounds", as: :review_rounds, only: :show
      resources :rules, controller: "review_rules", as: :review_rules, except: :destroy do
        member do
          post :rollback
          post :preview
        end
      end
    end

    # Agents: the list with its task routing, shared context and identities tabs, an
    # agent's page and form, and its avatar. A task type is given to an agent
    # with a PATCH to task_assignments/<task type>.
    resources :agents, only: %i[index show new create edit update] do
      member { get :avatar }
      collection { patch :context }
    end
    resources :task_assignments, only: :update
    # Identities: the accounts agents act as. The list is a tab of the
    # Agents page (agents?tab=identities).
    resources :identities, only: %i[new create edit update destroy]

    # Workflows: the list, a workflow's page and builder, the reference, and
    # each run's page. A host adds actions of its own under the same
    # addresses in its own routes.
    resources :workflows, param: :key, except: :destroy do
      member do
        post :run
        patch :mode
        post :test
      end
      collection { get :reference }
    end
    resources :workflow_runs, only: %i[index show] do
      member do
        post :cancel
        post :rerun
        post "steps/:step_run_id/decide", action: :decide, as: :decide
      end
    end

    # Models: providers and their usage, and the aliases agents are given.
    resources :models, only: :index do
      collection { post :refresh }
    end
    resources :model_aliases, except: %i[index show]
    resources :model_providers, only: :update

    # Where work runs: runtimes (places with limits) and workspaces (ordered
    # fallback lists of runtimes that agents pick).
    resources :runtimes, except: :show do
      member do
        post :check
        # A runtime that makes a machine for each run: remove the ones
        # finished runs left behind, and forget one a person has checked.
        post :sweep
        delete "machines/:machine_id", action: :forget_machine, as: :forget_machine
      end
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
