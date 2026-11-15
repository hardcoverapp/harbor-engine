module Harbor
  module Overview
    # The live configuration Overview is drawn from, loaded once per page:
    # task routing, agents and their models, workflows, automations, and run
    # timings. Each stage's parts read from here, so the page makes a fixed
    # number of queries however many stages there are.
    class Snapshot
      Route = Struct.new(:task_type, :agent, :model, :effort, :source, keyword_init: true)

      attr_reader :since

      def initialize(since: Harbor::Overview::WINDOW.ago)
        @since = since
      end

      def stages = @stages ||= Harbor::Overview.stages

      # A stage's parts, each a lambda: Harbor's five, then the ones a host
      # added (Harbor::Overview.part), by name.
      def parts_for(stage)
        {
          routing:     -> { routing_for(stage) },
          workflows:   -> { workflows_for(stage) },
          automations: -> { automations_for(stage) },
          timings:     -> { timings_for(stage) },
          steering:    -> { Harbor::Overview.steering_for(stage.key) },
          **Harbor::Overview.parts.to_h { |part| [ part.name, -> { Array(part.block.call(stage, self)) } ] }
        }
      end

      # --- who does it ---

      def routing_for(stage)
        types = stage.everything ? Harbor::TaskTypes.keys : stage.task_types.select { |type| Harbor::TaskTypes.declared?(type) }
        types.map { |type| route(type) }
      end

      # Mirrors Harbor::TaskAssignment.agent_for (the type's own row, its
      # fallback's row, its default agent) without a query per task.
      def route(task_type)
        type = Harbor::TaskTypes.declared?(task_type) ? Harbor::TaskTypes.find(task_type) : nil
        row = assignments[task_type]
        source = "assigned"
        if row.nil? && type&.fallback
          row = assignments[type.fallback]
          source = "falls back to #{type.fallback}"
        end
        agent = row&.agent
        if agent.nil? && type&.default_agent
          agent = agents[type.default_agent]
          source = "default"
        end
        agent = nil if agent && !agent.enabled?
        Route.new(task_type:, agent:, source: agent ? source : "unassigned", model: agent&.model_label, effort: agent&.effort_label)
      end

      # --- what it runs ---

      def workflows_for(stage) = workflows_by_stage.fetch(stage.key, [])
      def automations_for(stage) = automations_by_stage.fetch(stage.key, [])

      # Configuration no stage holds, so nothing live is left off the page.
      def unplaced_workflows = workflows_by_stage.fetch(nil, [])
      def unplaced_automations = automations_by_stage.fetch(nil, [])

      def unplaced_task_types
        return [] if stages.any?(&:everything)
        Harbor::TaskTypes.keys - stages.flat_map(&:task_types)
      end

      # --- how long, what it costs ---

      def timings_for(stage)
        return timings.values.sort_by(&:task_type) if stage.everything
        stage.task_types.filter_map { |type| timings[type] }
      end

      def timings = @timings ||= Timings.by_task_type(since:)

      def assignments = @assignments ||= Harbor.task_assignment_class.includes(agent: { model_alias: :model_choices }).index_by(&:task_type)

      def agents = @agents ||= Harbor.agent_class.includes(model_alias: :model_choices).index_by(&:key)

      def workflows = @workflows ||= Harbor.workflow_class.ordered.includes(:current_version).to_a

      def automations = @automations ||= Harbor.automation_class.ordered.to_a

      private
        def everything = stages.find(&:everything)

        # Each workflow sits in one stage: the flow it claims, else its first
        # trigger a stage starts on, else the task of its first agent step.
        def workflows_by_stage
          @workflows_by_stage ||= workflows.group_by do |workflow|
            next everything.key if everything
            definition = workflow.definition
            stages.find { |stage| (stage.claims & Array(workflow.claims)).any? }&.key ||
              definition.triggers.lazy.filter_map { |trigger| stages.find { |stage| stage.starts_on?(trigger) } }.first&.key ||
              definition.each_step.lazy.filter_map { |step, _|
                task = step["agent"].to_s.delete_prefix("task:") if step["agent"].to_s.start_with?("task:")
                task && Harbor::Overview.stage_for_task(task)
              }.first&.key
          end
        end

        # An automation sits in the stage that names it, else the first one
        # that starts on what starts it.
        def automations_by_stage
          @automations_by_stage ||= automations.group_by do |automation|
            next everything.key if everything
            stages.find { |stage| stage.automations.include?(automation.key) }&.key ||
              Array(automation.trigger_data).lazy.filter_map { |trigger| stages.find { |stage| stage.starts_on?(trigger) } }.first&.key
          end
        end
    end
  end
end
