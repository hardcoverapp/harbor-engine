module Harbor
  module Workflows
    # Everything a workflow can be built from, as the builder and the
    # reference page read it: the triggers, the data a step can read, the
    # modules (step types and actions), and the gates that decide what runs.
    # All of it comes from what is registered (Harbor::Workflows), so the
    # builder, the reference and validation can't drift apart.
    #
    # Field kinds the builder knows how to edit:
    #   text, template (a line with {{…}} data), textarea (a template over
    #   several lines), number, bool, select, multi (a list of strings; with
    #   `suggest_from` and `suggestions` it offers the values that go with
    #   another field's), condition (a filter), agent, workflow, workspace (a
    #   step registered as `makes_workspace`, or one of the field's own
    #   `options`), kv (named template values).
    module Catalog
      module_function

      OPERATORS = [
        { op: "eq", label: "equals", arity: 1 },
        { op: "ne", label: "doesn't equal", arity: 1 },
        { op: "in", label: "is one of", arity: :many },
        { op: "not_in", label: "is none of", arity: :many },
        { op: "contains", label: "contains", arity: 1 },
        { op: "present", label: "exists", arity: 0 },
        { op: "blank", label: "doesn't exist", arity: 0 },
        { op: "gt", label: ">", arity: 1 },
        { op: "gte", label: "≥", arity: 1 },
        { op: "lt", label: "<", arity: 1 },
        { op: "lte", label: "≤", arity: 1 }
      ].freeze

      TRIGGER_GATE = { name: "Trigger filter", where: "on the link after a trigger", reads: "trigger.*",
                       does: "The workflow only starts when the event passes it." }.freeze
      ON_ERROR_GATE = { name: "If it fails", where: "every step's settings", reads: "—",
                        does: "Stop the run (the default) or carry on to the next step." }.freeze

      def triggers = Harbor::Workflows.trigger_entries.map(&:to_catalog)

      def modules = Harbor::Workflows.step_entries.map(&:to_module)

      def settings = Harbor::Workflows.setting_entries.map(&:to_field)

      # What decides whether, and which, steps run: a trigger's filter, each
      # step type registered as a gate, and every step's "If it fails".
      def gates
        noted = Harbor::Workflows.step_entries.select(&:gate_note).map do |entry|
          { name: Harbor::Workflows.value(entry.label), type: entry.type }.merge(entry.gate_note)
        end
        [ TRIGGER_GATE, *noted, ON_ERROR_GATE ]
      end

      def data = { trigger: Harbor::Workflows.data(:trigger), run: Harbor::Workflows.data(:run) }

      # Everything at once, for the builder. `reference_url` is where its
      # help panel links to.
      def to_builder(workflows: [], agents: [], reference_url: nil)
        {
          triggers:, modules:, gates:, operators: OPERATORS, settings:,
          data:,
          workflows:, agents:,
          task_types: Harbor::TaskTypes.keys,
          max_loop: Harbor::Workflows::MAX_LOOP,
          reference_url:
        }.compact
      end

      def module_for(step) = Harbor::Workflows.step_for(step)&.to_module
    end
  end
end
