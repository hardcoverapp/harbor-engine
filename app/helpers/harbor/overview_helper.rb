module Harbor
  # What Overview needs to say its parts in words.
  module OverviewHelper
    # Whether the host has a partial of its own for a place on Overview
    # (app/views/harbor/overview/_<name>.html.erb in the host).
    def harbor_overview_partial?(name) = lookup_context.exists?("harbor/overview/#{name}", [], true)

    # The Turbo frame a stage's note is edited in: its id, and the frame
    # itself (written out, so a host needs no turbo-rails to draw it).
    def harbor_stage_note_frame(stage) = "factory-note-#{stage.key}"

    def harbor_stage_note_frame_tag(stage, &block) = content_tag("turbo-frame", capture(&block), id: harbor_stage_note_frame(stage))

    # Text a person wrote, as the host renders markdown (`config.markdown`);
    # without that, as plain paragraphs.
    def harbor_markdown(text)
      return "".html_safe if text.blank?
      renderer = Harbor.config.markdown
      renderer ? renderer.call(text.to_s).to_s.html_safe : simple_format(h(text))
    end

    # The same for one line inside a sentence: one paragraph, with no <p>.
    def harbor_inline_markdown(text)
      return h(text) unless Harbor.config.markdown
      harbor_markdown(text).to_s.strip.delete_prefix("<p>").delete_suffix("</p>").html_safe
    end

    # "Wren · Opus · high effort"
    def harbor_route_label(route)
      return "unassigned" unless route.agent
      [ route.agent.display_name, route.model, (route.effort.present? ? "#{route.effort} effort" : nil) ].compact.join(" · ")
    end

    def harbor_enabled_pill(enabled)
      enabled ? tag.span("on", class: "pill bg-pale-green text-ink-green") : tag.span("off", class: "pill bg-bone text-faint border border-hairline")
    end
  end
end
