module Harbor
  # What the Runs pages need to say a run in words.
  module RunsHelper
    # "42s", "6m", "2h 5m": how long something took, at a glance.
    def harbor_short_duration(seconds)
      return nil unless seconds
      seconds = seconds.to_i
      return "#{seconds}s" if seconds < 60
      return "#{seconds / 60}m" if seconds < 3600
      "#{seconds / 3600}h #{(seconds % 3600) / 60}m"
    end

    # The name of the agent a run belongs to, or its key when no such agent
    # exists any more. The names are read once per page.
    def harbor_run_agent_name(run)
      @harbor_agent_names ||= Harbor.agent_class.pluck(:key, :name).to_h
      @harbor_agent_names[run.agent_key].presence || run.agent_key
    end

    # Where a run was placed, or nil for one that never was.
    def harbor_run_runtime(run) = run.runtime_id && Harbor.runtime_class.find_by(id: run.runtime_id)

    def harbor_run_stoppable?(run) = Harbor::RunStop.possible?(run)

    # Whether the host has a partial of its own for a place on these pages
    # (app/views/harbor/runs/_<name>.html.erb in the host).
    def harbor_runs_partial?(name) = lookup_context.exists?("harbor/runs/#{name}", [], true)

    # A workflow run's page, wherever it lives: Harbor's own once it has one,
    # the host's until then, nil when neither has one.
    def harbor_workflow_run_path(id)
      return harbor.workflow_run_path(id) if harbor.respond_to?(:workflow_run_path)
      main_app.workflow_run_path(id) if main_app.respond_to?(:workflow_run_path)
    end
  end
end
