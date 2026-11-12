module Harbor
  # The pages a site can switch off. Each has a setting on the Settings page,
  # on by default. Switched off, a page leaves the menu and its controllers
  # answer as not found (Harbor::PageGate); nothing running in the background
  # is stopped by it.
  module Pages
    GROUP = "Pages".freeze

    class << self
      def setting_key(page) = "page_#{page}"

      def declare(page, label:)
        return if Settings.declared?(setting_key(page))

        Settings.declare setting_key(page),
          type: :boolean, default: true, group: GROUP, label: label,
          description: "Shows #{label} in the menu and lets its pages be opened. " \
                       "Off, it leaves the menu and its pages answer as not found. Nothing running in the background stops."
      end

      # A page with no switch is always on.
      def enabled?(page)
        key = setting_key(page)
        !Settings.declared?(key) || Harbor::Setting.get(key) == true
      end

      # Which of these pages are switched off, with one query.
      def switched_off(pages)
        keys = pages.map { |page| setting_key(page) }.select { |key| Settings.declared?(key) }
        return [] if keys.empty?

        values = Harbor::Setting.get_many(keys)
        pages.select { |page| values[setting_key(page)] == false }.map(&:to_sym)
      end
    end
  end
end
