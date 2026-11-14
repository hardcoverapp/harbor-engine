module Harbor
  # A parked step: something a step is waiting for, with what to match
  # (`matcher`) and when to give up (`expires_at`). A host with steps that
  # wait for events finds the waits an event answers, finishes their step
  # runs and destroys them; Harbor::Workflows.sweep_waits! times out the ones
  # past their expiry.
  class WorkflowWait < ApplicationRecord
    self.table_name = "workflow_waits"

    belongs_to :workflow_run, class_name: Harbor.class_name_for(:workflow_run_class)
    belongs_to :workflow_step_run, class_name: "Harbor::WorkflowStepRun"

    scope :expired, ->(now = Time.current) { where("expires_at IS NOT NULL AND expires_at <= ?", now) }
  end
end
