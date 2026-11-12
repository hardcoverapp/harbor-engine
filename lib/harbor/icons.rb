module Harbor
  # The icons Harbor's menu uses: 24×24, drawn with a stroke. A menu entry
  # names one (`icon: :runs`), or carries its own SVG markup.
  module Icons
    PATHS = {
      overview:    '<rect x="3" y="3" width="7" height="9" rx="1"/><rect x="14" y="3" width="7" height="5" rx="1"/><rect x="14" y="12" width="7" height="9" rx="1"/><rect x="3" y="16" width="7" height="5" rx="1"/>',
      velocity:    '<path d="m22 7-8.5 8.5-5-5L2 17"/><path d="M16 7h6v6"/>',
      workflows:   '<circle cx="6" cy="6" r="2.5"/><circle cx="18" cy="18" r="2.5"/><path d="M8.5 6H14a4 4 0 0 1 4 4v5.5"/>',
      automations: '<circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/>',
      runs:        '<circle cx="12" cy="12" r="9"/><path d="m10 8.5 5.5 3.5-5.5 3.5z"/>',
      webhooks:    '<path d="M18 17h-6c-1.1 0-2 .9-2.5 1.9A4 4 0 0 1 2 17c0-.7.2-1.4.6-2"/><path d="m6 17 3.1-5.8c.5-1 .1-2.2-.5-3.1a4 4 0 1 1 6.9-4"/><path d="m12 6 3.1 5.7c.5 1 1.8 1.3 2.9 1.3a4 4 0 0 1 0 8"/>',
      agents:      '<rect x="4" y="8" width="16" height="11" rx="2"/><path d="M12 8V4M9 13v2M15 13v2"/>',
      models:      '<rect x="6" y="6" width="12" height="12" rx="2"/><path d="M9 2v4M15 2v4M9 18v4M15 18v4M2 9h4M2 15h4M18 9h4M18 15h4"/>',
      runtimes:    '<rect x="3" y="4" width="18" height="7" rx="2"/><rect x="3" y="13" width="18" height="7" rx="2"/><path d="M7 7.5h.01M7 16.5h.01"/>',
      workspaces:  '<path d="m12 3 9 5-9 5-9-5 9-5z"/><path d="m3 13 9 5 9-5"/>',
      database:    '<ellipse cx="12" cy="5.5" rx="8" ry="3"/><path d="M4 5.5v13c0 1.7 3.6 3 8 3s8-1.3 8-3v-13M4 12c0 1.7 3.6 3 8 3s8-1.3 8-3"/>',
      reviews:     '<path d="M12 3 5 6v5c0 4.5 3 8.3 7 10 4-1.7 7-5.5 7-10V6l-7-3z"/><path d="m9 12 2 2 4-4"/>',
      scorers:     '<circle cx="12" cy="12" r="9"/><circle cx="12" cy="12" r="5"/><circle cx="12" cy="12" r="1"/>',
      proposals:   '<path d="M9 18h6M10 21h4M12 3a6 6 0 0 0-4 10.5c.7.7 1 1.5 1 2.5h6c0-1 .3-1.8 1-2.5A6 6 0 0 0 12 3z"/>',
      settings:    '<path d="M4 21v-7M4 10V3M12 21v-9M12 8V3M20 21v-5M20 12V3M1 14h6M9 8h6M17 16h6"/>',
      page:        '<path d="M14 3H7a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V8z"/><path d="M14 3v5h5"/>',
      collapse:    '<path d="m11 17-5-5 5-5M18 17l-5-5 5-5"/>'
    }.freeze

    # The inner SVG markup for an icon: a name from PATHS, or markup passed
    # through. An unknown or missing name is the plain page icon.
    def self.markup(icon)
      return icon if icon.is_a?(String) && icon.include?("<")
      PATHS.fetch(icon.to_s.to_sym) { PATHS[:page] }
    end
  end
end
