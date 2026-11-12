module Harbor
  class Engine < ::Rails::Engine
    isolate_namespace Harbor

    # The host runs Harbor's migrations with its own: one schema, one
    # `db:migrate`. No copying into the host's db/migrate.
    initializer "harbor.migrations" do |app|
      # Harbor's own test app lives inside the engine, where Rails' engine
      # tasks already add these.
      next if app.root.to_s.start_with?(root.to_s)

      host_paths = app.config.paths["db/migrate"]
      config.paths["db/migrate"].expanded.each do |path|
        host_paths << path unless host_paths.expanded.include?(path)
      end
    end

    initializer "harbor.nav_helper" do
      ActiveSupport.on_load(:action_controller_base) { helper Harbor::NavHelper }
    end
  end
end
