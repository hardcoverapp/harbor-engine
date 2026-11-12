module Harbor
  # Available in every host view: Harbor's menu, and the pieces a host's layout
  # needs to draw the section the way Harbor does.
  module NavHelper
    # Every page of the menu, in the order it is drawn.
    def harbor_nav_links = harbor_nav_groups.flat_map(&:links)

    # The menu by group (Harbor::Nav::Group: key, heading, links).
    def harbor_nav_groups
      @harbor_nav_groups ||= Harbor.nav.groups(self)
    end

    def harbor_nav_active?
      harbor_nav_links.any?(&:active)
    end

    # True on a page of Harbor's section: one that asked for the side nav. A
    # layout uses it to draw the section's shell around the page.
    def harbor_section? = content_for?(:harbor_nav)

    # An icon by name (Harbor::Icons::PATHS) or from its own SVG markup.
    def harbor_icon(icon, size: 16)
      content_tag(:svg, Harbor::Icons.markup(icon).html_safe, viewBox: "0 0 24 24", width: size, height: size, fill: "none",
                        stroke: "currentColor", "stroke-width": 1.8, "stroke-linecap": "round", "stroke-linejoin": "round",
                        "aria-hidden": true, class: "harbor-icon")
    end

    # Goes in the layout's <head>. The side nav remembers being collapsed; this
    # applies it before the page is drawn, so it doesn't open and snap shut on
    # every visit.
    def harbor_nav_state_tag
      javascript_tag(<<~JS.squish, nonce: true)
        try { if (localStorage.getItem("harborNav") === "collapsed") document.documentElement.dataset.harborNavState = "collapsed" } catch (e) {}
      JS
    end
  end
end
