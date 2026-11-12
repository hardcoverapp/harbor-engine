module Harbor
  # How a status reads on a page, and links to the things statuses belong to.
  # Available in every host view, like the menu helpers.
  module StatusHelper
    MUTED = "bg-bone text-soft border border-hairline".freeze
    # Colour is semantic only: green went well, red didn't, blue is under way,
    # yellow is waiting on something.
    STATUS_CLASSES = {
      "queued" => MUTED, "skipped" => MUTED, "canceled" => MUTED, "received" => MUTED,
      "ignored" => "bg-bone text-faint border border-hairline",
      "waiting_for_model" => "bg-pale-yellow text-ink-yellow", "timeout" => "bg-pale-yellow text-ink-yellow",
      "waiting" => "bg-pale-yellow text-ink-yellow",
      "running" => "bg-pale-blue text-ink-blue", "dispatched" => "bg-pale-blue text-ink-blue",
      "ok" => "bg-pale-green text-ink-green", "succeeded" => "bg-pale-green text-ink-green",
      "error" => "bg-pale-red text-ink-red", "failed" => "bg-pale-red text-ink-red"
    }.freeze

    def harbor_status_pill(status)
      content_tag(:span, status.to_s.tr("_", " "), class: "pill #{STATUS_CLASSES.fetch(status.to_s, MUTED)}", data: { status: status })
    end

    # A link to a run's page, wherever that page lives: Harbor's own once it
    # has one, the host's until then. Plain text when neither has a run page.
    def harbor_run_link(run, **options)
      path = harbor_run_path(run)
      path ? link_to("Run ##{run.id}", path, **options) : content_tag(:span, "Run ##{run.id}", **options)
    end

    def harbor_run_path(run)
      return harbor.run_path(run) if harbor.respond_to?(:run_path)
      main_app.run_path(run) if main_app.respond_to?(:run_path)
    end
  end
end
