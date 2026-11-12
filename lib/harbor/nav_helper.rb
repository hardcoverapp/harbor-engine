module Harbor
  # Available in every host view, so the host's layout can render the menu.
  module NavHelper
    def harbor_nav_links
      @harbor_nav_links ||= Harbor.nav.links(self)
    end

    def harbor_nav_active?
      harbor_nav_links.any?(&:active)
    end
  end
end
