module Harbor
  # How an agent is drawn on a page. Available in every host view, like the
  # menu helpers.
  module AgentHelper
    # The size classes are the host's own utilities, like the rest of what
    # Harbor's pages are drawn with.
    AVATAR_SIZES = { xs: "h-4 w-4 text-[8px]", sm: "h-5 w-5 text-[9px]", md: "h-7 w-7 text-[11px]",
                     lg: "h-10 w-10 text-sm", xl: "h-20 w-20 text-2xl" }.freeze

    # An agent's avatar: the image it was given, else the first letter of its
    # name ("?" for one with no name yet). The image's address changes when the agent does, so a browser's
    # copy is never out of date.
    def harbor_agent_avatar(agent, size: :lg)
      classes = "#{AVATAR_SIZES.fetch(size)} shrink-0 rounded-full bg-bone border border-hairline"
      if agent.persisted? && agent.avatar?
        image_tag harbor_agent_avatar_path(agent), alt: "", loading: "lazy", class: "#{classes} object-cover"
      else
        tag.span(agent.display_name.to_s.first.presence&.upcase || "?", aria: { hidden: true },
                 class: "#{classes} text-soft font-medium inline-flex items-center justify-center")
      end
    end

    def harbor_agent_avatar_path(agent) = harbor.avatar_agent_path(agent, v: agent.updated_at.to_f)
  end
end
