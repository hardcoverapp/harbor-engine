module Harbor
  # The section menu: Harbor's pages and the host's own, in groups, each with an
  # icon. The side nav beside every page, and whatever menus the host's layout
  # draws from it, all read this one list, so a page is added, renamed or moved
  # in one place.
  #
  # An item names a route helper instead of a path, so it resolves wherever the
  # engine is mounted. `scope` says whose routes the helper belongs to:
  # `:main_app` for the host's, `:harbor` for the engine's own.
  #
  # An item with a `key` is a page the site can switch off on the Settings
  # page (Harbor::Pages); switched off, it is left out of the menu.
  class Nav
    Item = Struct.new(:label, :route, :scope, :also, :key, :group, :icon, keyword_init: true)
    Link = Struct.new(:label, :path, :active, :key, :group, :icon, keyword_init: true)
    Group = Struct.new(:key, :heading, :links, keyword_init: true)

    # The groups, in the order they are drawn. Related pages sit together under
    # a heading; every page is visible, none is behind a click. A group with no
    # heading stands alone (the first and the last).
    GROUPS = [
      [ :overview,       nil ],
      [ :flows,          "Flows" ],
      [ :activity,       "Activity" ],
      [ :agents,         "Agents" ],
      [ :infrastructure, "Infrastructure" ],
      [ :quality,        "Quality" ],
      [ :settings,       nil ]
    ].freeze

    # Harbor's pages. Most of their routes still live in the host Harbor is
    # being extracted from, and move here one area at a time; an entry switches
    # to `scope: :harbor` when its routes do. Until then an entry shows only in
    # a host that defines its route.
    DEFAULTS = [
      [ "Overview",      :factory_path,               { key: :overview,    group: :overview } ],
      [ "Velocity",      :velocity_path,              { key: :velocity,    group: :overview } ],
      [ "Workflows",     :workflows_path,             { key: :workflows,   group: :flows, also: [ "/workflow_runs" ] } ],
      [ "Automations",   :automations_path,           { key: :automations, group: :flows } ],
      [ "Runs",          :runs_path,                  { key: :runs,        group: :activity } ],
      [ "Webhooks",      :webhooks_path,              { key: :webhooks,    group: :activity, scope: :harbor } ],
      [ "Agents",        :agents_path,                { key: :agents,      group: :agents } ],
      [ "Models",        :models_path,                { key: :models,      group: :agents, also: [ "/model_aliases" ], scope: :harbor } ],
      [ "Runtimes",      :runtimes_path,              { key: :runtimes,    group: :infrastructure, scope: :harbor } ],
      [ "Workspaces",    :workspace_profiles_path,    { key: :workspaces,  group: :infrastructure, scope: :harbor } ],
      [ "Review policy", :reviews_path,               { key: :reviews,     group: :quality } ],
      [ "Scorers",       :scorers_path,               { key: :scorers,     group: :quality } ],
      [ "Proposals",     :improvement_proposals_path, { key: :proposals,   group: :quality } ],
      # No key: the page the switches are on can't be switched off.
      [ "Settings",      :settings_path,              { scope: :harbor,    group: :settings, icon: :settings } ]
    ].freeze

    def initialize
      @items = DEFAULTS.map do |label, route, opts|
        Item.new(label: label, route: route, scope: opts.fetch(:scope, :main_app), also: opts.fetch(:also, []),
                 key: opts[:key], group: opts[:group], icon: opts[:icon] || opts[:key])
      end
    end

    def items = @items.dup

    def labels = @items.map(&:label)

    # Add a page.
    #
    #   group:   which group it sits in: one of GROUPS' keys, or a new name,
    #            which becomes a group of its own after Harbor's
    #   icon:    a name from Harbor::Icons::PATHS, or SVG markup
    #   after: / before:  an existing label to sit next to; with neither, the
    #            page goes last in its group
    #   also:    extra path prefixes that count as this page
    #   key:     gives the page a switch on the Settings page, like Harbor's own
    def add(label, route, after: nil, before: nil, scope: :main_app, also: [], key: nil, group: nil, icon: nil)
      raise ArgumentError, "#{label.inspect} is already in the menu" if labels.include?(label)
      raise ArgumentError, "give after: or before:, not both" if after && before

      anchor = after || before
      index = anchor && (labels.index(anchor) or raise ArgumentError, "no menu entry named #{anchor.inspect}")
      # Next to a page means in that page's group, unless told otherwise.
      group ||= anchor ? @items[index].group : :more

      Pages.declare(key, label: label) if key
      item = Item.new(label: label, route: route, scope: scope, also: Array(also), key: key&.to_sym,
                      group: group.to_sym, icon: icon || key || :page)
      anchor ? @items.insert(after ? index + 1 : index, item) : @items << item
      item
    end

    def remove(label)
      @items.reject! { |item| item.label == label }
    end

    # The menu for one request, in the order it is drawn: each page's path and
    # whether the current page is under it. A page whose route doesn't exist is
    # left out, so a host shows only the pages it has, and so is one the site
    # has switched off.
    def links(view) = groups(view).flat_map(&:links)

    # The same, by group. A group with no page to show is left out, heading and
    # all. Groups the host named itself follow Harbor's, in the order added.
    def groups(view)
      current = view.request.path
      off = Pages.switched_off(@items.filter_map(&:key))
      shown = @items.filter_map do |item|
        next if off.include?(item.key)

        routes = view.public_send(item.scope)
        next unless routes.respond_to?(item.route)

        path = routes.public_send(item.route)
        active = [ path, *item.also ].any? { |prefix| under?(current, prefix) }
        Link.new(label: item.label, path: path, active: active, key: item.key, group: item.group, icon: item.icon)
      end

      known = GROUPS.to_h
      order = GROUPS.map(&:first) | shown.map(&:group)
      order -= [ :settings ]
      order << :settings
      order.filter_map do |key|
        links = shown.select { |link| link.group == key }
        next if links.empty?

        Group.new(key: key, heading: known.fetch(key) { key.to_s.humanize }, links: links)
      end
    end

    private
      # "/runs" covers "/runs" and "/runs/12", not "/runsheet".
      def under?(current, prefix)
        current == prefix || current.start_with?("#{prefix.chomp('/')}/")
      end
  end
end
