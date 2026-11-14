module Harbor
  # One saved definition of a workflow. Never changed once saved: a run keeps
  # the version it started on.
  class WorkflowVersion < ApplicationRecord
    self.table_name = "workflow_versions"

    belongs_to :workflow, class_name: Harbor.class_name_for(:workflow_class)
    has_many :workflow_runs, class_name: Harbor.class_name_for(:workflow_run_class), foreign_key: :workflow_version_id,
                             dependent: :restrict_with_exception, inverse_of: :workflow_version
    # Who saved it, when the host has told Harbor its user class.
    if Harbor.config.user_class
      belongs_to :created_by_user, class_name: Harbor.class_name_for(:user_class), optional: true
    end

    def parsed = Harbor::Workflows::Definition.parse(definition)

    # The host's user who saved it, or nil.
    def saved_by = Harbor.config.user_class ? created_by_user : nil
  end
end
