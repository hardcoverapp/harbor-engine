module Harbor
  # One parsed event of an agent run's stream (assistant text, a tool use, an
  # API retry, the result, or an unknown type kept raw). `summary` is the short
  # line a run page lists; `payload` is capped, the full record being the raw
  # stream the run points at.
  class RunEvent < ApplicationRecord
    self.table_name = "run_events"

    belongs_to :run, class_name: Harbor.class_name_for(:run_class), inverse_of: :run_events

    scope :ordered, -> { order(:seq) }
    scope :tool_uses, -> { where(event_type: "assistant").where.not(tool_name: nil) }
  end
end
