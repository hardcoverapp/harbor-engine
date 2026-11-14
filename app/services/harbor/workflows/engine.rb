module Harbor
  module Workflows
    # Moves one workflow run forward as far as it can, then stops.
    #
    # The engine replays the definition from the top on every advance. A step
    # that already has a WorkflowStepRun in its scope isn't re-executed: its
    # recorded output goes back into the context and the walk continues. The
    # first step that hasn't run yet is started; if it finishes immediately
    # (actions, choices) the walk goes on, and if it has to
    # wait (an agent's Run, an event, a person's approval, a child
    # workflow) the walk stops. Whatever finishes that step enqueues
    # AdvanceJob again.
    #
    # Because everything the walk needs is in Postgres, a restart loses nothing:
    # advancing again just replays. Conditions only read recorded outputs, so a
    # replay always takes the same path.
    #
    # Phases: main → finally (cleanup steps, run whatever main ended as, so
    # what a run set up is always torn down) → done.
    #
    # A leaf step is run by what its type registered (Harbor::Workflows):
    # `start(engine, step, step_run, input)` finishes the step run and
    # returns :done, or leaves it pending and returns :blocked.
    class Engine
      # Returns the run when this advance finished it; nil when the run is
      # parked on a step, was already done, or isn't there.
      def self.advance!(workflow_run_id)
        run = Harbor.workflow_run_class.find_by(id: workflow_run_id)
        new(run).advance! if run
      end

      attr_reader :run, :context

      def initialize(run)
        @run = run
      end

      def advance!
        finished = false
        run.with_lock do
          return if run.phase == "done"
          @definition = run.definition
          @context = Context.new(run.context)
          @steps = run.step_runs.reload.index_by { |s| [ s.scope, s.step_key ] }
          run.update!(status: "running", started_at: Time.current) if run.status == "queued"

          if run.phase == "main"
            result = run.outcome == "canceled" ? :failed : walk(@definition.steps, "")
            result = :done if result == :halt
            if result == :blocked
              park!
              return
            end
            run.update!(phase: "finally", outcome: run.outcome || (result == :failed ? "failed" : "succeeded"),
                        note: (@halt_note || run.note))
          end

          result = walk(@definition.finally_steps, "finally/")
          result = :done if result == :halt
          if result == :blocked
            park!
            return
          end
          run.update!(context: context.data)
          run.update!(error: [ run.error, "a cleanup step failed" ].compact.join("; ")) if result == :failed
          run.finish!(status: run.outcome)
          finished = true
        end
        notify_parent if finished
        run
      end

      private

      # "running" while something is working (a step type registered as
      # `working`, such as an agent); "waiting" while the run is only parked on
      # an event, a person, or a called workflow. Containers (loops, choices)
      # are pending whenever something inside them is, so they don't count
      # either way.
      def park!
        working = run.step_runs.pending.where(step_type: Harbor::Workflows.types_where(:working)).exists?
        run.update!(context: context.data, status: working ? "running" : "waiting")
      end

      # :done, :blocked (something is pending), :failed, or :halt (dry run hit a
      # wait — the dry run ends there).
      def walk(list, scope, iteration: nil)
        list.each do |step|
          result = case step["type"]
          when "choice" then exec_choice(step, scope, iteration)
          when "loop"   then exec_loop(step, scope)
          when "filter" then exec_filter(step, scope, iteration)
          else exec_leaf(step, scope, iteration)
          end
          return result unless result == :done
        end
        :done
      end

      def exec_leaf(step, scope, iteration)
        key = step["key"]
        sr = @steps[[ scope, key ]]
        if sr
          return :blocked if sr.pending?
          record(sr)
          return outcome_of(sr, step)
        end

        input = context.render_deep(step.except("steps", "branches", "otherwise"))
        sr = create_step_run(step, scope, input, iteration)

        entry = Harbor::Workflows.step_for(step)
        if run.dry_run? && entry&.dry_run_stop
          sr.finish!(status: "skipped", output: { "dry_run" => true, "note" => "a dry run stops at the first wait" })
          record(sr)
          @halt_note = "Dry run: stopped at #{step['name'] || key}, #{entry.dry_run_stop}."
          return :halt
        end
        # A step that acts outside the run is recorded in a dry run, not run.
        if run.dry_run? && (entry ? entry.side_effect : step["type"] == "action")
          sr.finish!(status: "skipped", output: { "dry_run" => true, "would" => input })
          record(sr)
          return :done
        end

        begin
          raise ArgumentError, "unknown step type #{step['type']}" unless entry
          result = entry.runner_object.start(self, step, sr, input)
        rescue => e
          sr.finish!(status: "error", error: "#{e.class}: #{e.message}")
          result = :done
        end
        return :blocked if result == :blocked
        record(sr.reload)
        outcome_of(sr, step)
      end

      def exec_choice(step, scope, iteration)
        key = step["key"]
        sr = @steps[[ scope, key ]]
        branches = Array(step["branches"])
        unless sr
          index = branches.index { |b| Condition.evaluate(b["when"], context) }
          label = index ? (branches[index]["name"].presence || "branch #{index + 1}") : "otherwise"
          sr = create_step_run(step, scope, { "branches" => branches.map { |b| Condition.describe(b["when"]) } }, iteration)
          sr.update!(output: { "branch" => label, "index" => index })
        end
        index = sr.output["index"]
        list = index.nil? ? Array(step["otherwise"]) : Array(branches[index]&.dig("steps"))
        result = walk(list, scope, iteration:)
        return result unless result == :done
        sr.finish!(status: "ok") if sr.pending?
        record(sr)
        :done
      end

      # A filter that doesn't pass stops the run there, like a filter on a link
      # in Make: nothing after it runs, cleanup still does, and the run counts
      # as succeeded. Replays read the recorded result, so they stop again.
      def exec_filter(step, scope, iteration)
        key = step["key"]
        sr = @steps[[ scope, key ]]
        unless sr
          passed = Condition.evaluate(step["when"], context)
          sr = create_step_run(step, scope, { "when" => Condition.describe(step["when"]) }, iteration)
          sr.finish!(status: "ok", output: { "passed" => passed })
        end
        record(sr)
        return :done if sr.output["passed"]
        @halt_note = "Stopped at #{step['name'].presence || key}: #{Condition.describe(step['when'])} didn't pass."
        :halt
      end

      def exec_loop(step, scope)
        key = step["key"]
        sr = @steps[[ scope, key ]] || create_step_run(step, scope, { "max_iterations" => step["max_iterations"] }, nil)
        max = step["max_iterations"].to_i
        (1..max).each do |i|
          context.data["loop"] = context.data["loop"].to_h.merge(key => { "iteration" => i })
          result = walk(Array(step["steps"]), "#{scope}#{key}[#{i}]/", iteration: i)
          return result unless result == :done
          next unless step["until"].present? && Condition.evaluate(step["until"], context)
          sr.finish!(status: "ok", output: { "result" => "converged", "iterations" => i }) if sr.pending?
          record(sr)
          return :done
        end
        result = step["until"].present? ? "exhausted" : "completed"
        sr.finish!(status: "ok", output: { "result" => result, "iterations" => max }) if sr.pending?
        record(sr)
        :done
      end

      def create_step_run(step, scope, input, iteration)
        sr = run.step_runs.create!(step_key: step["key"], step_type: step["type"], scope:, iteration:,
                                   status: "running", input:, started_at: Time.current)
        @steps[[ scope, step["key"] ]] = sr
      end

      def record(sr)
        context.record(sr.step_key, sr.output.to_h.merge("status" => sr.status), iteration: sr.iteration)
      end

      def outcome_of(sr, step)
        return :done if sr.ok? || sr.status == "skipped"
        step["on_error"] == "continue" ? :done : :failed
      end

      # A `call` step's child finished: hand its result to the parent's step.
      def notify_parent
        parent = run.parent_workflow_run or return
        sr = parent.step_runs.pending.find_by(step_key: run.parent_step_key, step_type: "call") or return
        sr.finish!(status: run.status == "succeeded" ? "ok" : "error",
                   output: { "child_run_id" => run.id, "result" => run.status, "steps" => run.context["steps"] },
                   error: (run.error if run.status != "succeeded"))
        Harbor::Workflows.advance_later(parent.id)
      end
    end
  end
end
