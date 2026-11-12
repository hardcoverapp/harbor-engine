module Harbor
  # One runtime in a workspace's list, at a position.
  class WorkspaceProfileRuntime < ApplicationRecord
    self.table_name = "workspace_profile_runtimes"

    belongs_to :workspace_profile, class_name: Harbor.class_name_for(:workspace_profile_class), inverse_of: :workspace_profile_runtimes
    belongs_to :runtime, class_name: Harbor.class_name_for(:runtime_class)

    validates :position, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
    validates :runtime_id, uniqueness: { scope: :workspace_profile_id, message: "is already in this workspace" }
  end
end
