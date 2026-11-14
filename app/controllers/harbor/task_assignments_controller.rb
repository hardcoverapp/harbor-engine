module Harbor
  # One action: give a task type to another agent, from those it may be given
  # to. It takes effect on the next dispatch, with no deploy or restart.
  class TaskAssignmentsController < ApplicationController
    harbor_page :agents

    def update
      task_type = params[:id].to_s
      unless Harbor::TaskTypes.declared?(task_type)
        return redirect_to agents_path(tab: "routing"), alert: "#{task_type.inspect} isn't a task type."
      end

      assignments = Harbor.task_assignment_class
      agent = assignments.compatible_agents(task_type).find_by(key: params[:agent_key])
      if agent.nil?
        return redirect_to agents_path(tab: "routing"), alert: assignments.refusal(task_type, params[:agent_key])
      end

      assignments.find_or_initialize_by(task_type:).update!(agent_key: agent.key)
      redirect_to agents_path(tab: "routing"), notice: "#{task_type} → #{agent.key} (next run uses it)."
    end
  end
end
