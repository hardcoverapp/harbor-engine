module Harbor
  # How workflows, their steps and their runs read on a page.
  module WorkflowsHelper
    DEFAULT_PILL = "bg-bone text-soft".freeze
    STEP_STATUS_CLASSES = {
      "ok" => "bg-pale-green text-ink-green", "error" => "bg-pale-red text-ink-red", "canceled" => "bg-pale-red text-ink-red",
      "skipped" => "bg-bone text-faint border border-hairline", "running" => "bg-pale-blue text-ink-blue",
      "waiting" => "bg-pale-yellow text-ink-yellow"
    }.freeze
    RUN_STATUS_CLASSES = {
      "succeeded" => "bg-pale-green text-ink-green", "failed" => "bg-pale-red text-ink-red", "canceled" => "bg-pale-red text-ink-red",
      "running" => "bg-pale-blue text-ink-blue", "waiting" => "bg-pale-yellow text-ink-yellow", "queued" => "bg-bone text-soft border border-hairline"
    }.freeze
    MODE_CLASSES = { "live" => "bg-pale-green text-ink-green", "dry_run" => "bg-pale-yellow text-ink-yellow", "off" => "bg-bone text-faint border border-hairline" }.freeze

    # Whether the host has a partial of its own for a place on these pages
    # (app/views/harbor/workflows/_<name>.html.erb in the host).
    def harbor_workflows_partial?(name) = lookup_context.exists?("harbor/workflows/#{name}", [], true)

    # A step type's word and colours, as its type registered them.
    def harbor_step_type_label(type) = harbor_step_entry(type)&.short || type

    def harbor_step_type_pill(type)
      content_tag(:span, harbor_step_type_label(type), class: "pill #{harbor_step_entry(type)&.pill || DEFAULT_PILL}")
    end

    def harbor_step_status_pill(status) = content_tag(:span, status, class: "pill #{STEP_STATUS_CLASSES.fetch(status, DEFAULT_PILL)}")
    def harbor_workflow_run_status_pill(status) = content_tag(:span, status, class: "pill #{RUN_STATUS_CLASSES.fetch(status, DEFAULT_PILL)}")
    def harbor_workflow_mode_pill(mode) = content_tag(:span, mode.to_s.tr("_", " "), class: "pill #{MODE_CLASSES.fetch(mode.to_s, DEFAULT_PILL)}")

    # How a workflow run stands, at a glance: a spinner while it runs, a pulsing
    # dot while it waits on an event, and a mark for how it ended.
    def harbor_workflow_run_mark(run)
      mark = case run.status
      when "running", "queued"
        content_tag(:span, "", role: "img", aria: { label: run.status.capitalize }, data: { run_mark: "running" },
                               class: "inline-block w-3 h-3 rounded-full border-2 border-ink-blue border-t-transparent animate-spin motion-reduce:animate-none")
      when "waiting"
        content_tag(:span, "", role: "img", aria: { label: "Waiting" }, data: { run_mark: "waiting" },
                               class: "inline-block w-2 h-2 rounded-full bg-ink-yellow animate-pulse motion-reduce:animate-none")
      else
        emoji, label = { "succeeded" => [ "✅", "Passed" ], "failed" => [ "❌", "Failed" ] }.fetch(run.status, [ "⏹️", run.status.capitalize ])
        content_tag(:span, emoji, role: "img", aria: { label: label }, data: { run_mark: run.status }, class: "text-xs leading-none")
      end
      # One width for every mark, so the run numbers beside them line up.
      content_tag(:span, mark, class: "inline-flex w-4 shrink-0 items-center justify-center")
    end

    def harbor_step_title(step) = step["name"].presence || step["key"].to_s.humanize

    # One line under a node saying what it does, as its type registered it.
    def harbor_step_summary(step) = Harbor::Workflows.step_for(step)&.summary&.call(step).to_s

    def harbor_trigger_summary(trigger)
      Harbor::Workflows.trigger(trigger["kind"])&.summary&.call(trigger) || trigger["kind"].to_s
    end

    def harbor_pretty_json(obj) = JSON.pretty_generate(obj.presence || {})

    # Who saved a version or started a run, as the host names its users; nil
    # when the host has no user class or nobody is recorded.
    def harbor_workflow_user(record, association)
      user = Harbor.config.user_class && record.public_send(association)
      user && Harbor.config.user_label.call(user)
    end

    # What the visual builder draws from: modules, triggers, data, operators,
    # plus the workflows and agents its pickers offer.
    def harbor_workflow_builder_catalog
      Harbor::Workflows::Catalog.to_builder(
        workflows: Harbor.workflow_class.ordered.map { |w| { key: w.key, name: w.name } },
        agents: Harbor.agent_class.where(enabled: true).order(:key).pluck(:key, :name).map { |key, name| { key:, name: } },
        reference_url: harbor.reference_workflows_path
      )
    end

    # Each step's latest state on a run, keyed by step key, for the canvas.
    def harbor_workflow_run_statuses(run, latest)
      counts = run.step_runs.group_by(&:step_key).transform_values(&:size)
      latest.to_h { |key, sr|
        out = sr.output.to_h
        [ key, {
          status: sr.status, url: harbor.workflow_run_path(run, step: sr.id, anchor: "step"), count: counts[key],
          verdict: out["verdict"], branch: out["branch"], index: out["index"], result: out["result"],
          iterations: out["iterations"], decision: out["decision"], passed: out["passed"]
        }.compact ]
      }
    end

    private
      # The first entry of a type: every action shares its type's pill.
      def harbor_step_entry(type) = Harbor::Workflows.step_entries.find { |entry| entry.type == type }
  end
end
