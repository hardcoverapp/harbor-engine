module Harbor
  # Which agent handles which kind of work. Dispatch asks `agent_for(task_type)`,
  # so changing who does a task is one row edited in the app, with no deploy.
  # The task types themselves are declared by the host (Harbor::TaskTypes).
  class TaskAssignment < ApplicationRecord
    self.table_name = "task_assignments"

    belongs_to :agent, class_name: Harbor.class_name_for(:agent_class), foreign_key: :agent_key, primary_key: :key,
                       inverse_of: :task_assignments

    validates :task_type, presence: true, uniqueness: true
    validate { errors.add(:task_type, "is not a declared task type") unless Harbor::TaskTypes.declared?(task_type) }
    validates :agent_key, presence: true

    # The agents a task type can be given to: every enabled one. A host whose
    # task types need a particular kind of agent narrows this in a subclass.
    def self.compatible_agents(_task_type) = Harbor.agent_class.enabled.order(:key)

    # The enabled agent for a task type: its own assignment, else its
    # fallback type's, else its default agent. nil when there is none or the
    # agent is switched off (callers treat that as "don't dispatch").
    def self.agent_for(task_type)
      type = Harbor::TaskTypes.declared?(task_type) ? Harbor::TaskTypes.find(task_type) : nil
      row = find_by(task_type: task_type.to_s)
      row = find_by(task_type: type.fallback) if row.nil? && type&.fallback
      agent = row ? row.agent : (Harbor.agent_class.find_by(key: type.default_agent) if type&.default_agent)
      agent if agent&.enabled?
    end
  end
end
