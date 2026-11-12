module Harbor
  # The section menu: one ordered list that the host's layout (desktop dropdown,
  # mobile sidebar) and the tabs above each page all render, so a page is added
  # or renamed in one place.
  #
  # An item names a route helper instead of a path, so it resolves wherever the
  # engine is mounted. `scope` says whose routes the helper belongs to:
  # `:main_app` for the host's, `:harbor` for the engine's own.
  #
  # An item with a `key` is a page the site can switch off on the Settings
  # page (Harbor::Pages); switched off, it is left out of the menu.
  class Nav
    Item = Struct.new(:label, :route, :scope, :also, :key, keyword_init: true)
    Link = Struct.new(:label, :path, :active, keyword_init: true)

    # Harbor's pages. Most of their routes still live in the host Harbor is
    # being extracted from, and move here one area at a time; an entry switches
    # to `scope: :harbor` when its routes do. Until then an entry shows only in
    # a host that defines its route.
    DEFAULTS = [
      [ "Overview",      :factory_path,               { key: :overview } ],
      [ "Velocity",      :velocity_path,              { key: :velocity } ],
      [ "Automations",   :automations_path,           { key: :automations } ],
      [ "Workflows",     :workflows_path,             { key: :workflows } ],
      [ "Review policy", :reviews_path,               { key: :reviews } ],
      [ "Runs",          :runs_path,                  { key: :runs } ],
      [ "Agents",        :agents_path,                { key: :agents } ],
      [ "Models",        :models_path,                { key: :models, also: [ "/model_aliases" ] } ],
      [ "Runtimes",      :runtimes_path,              { key: :runtimes } ],
      [ "Workspaces",    :workspace_profiles_path,    { key: :workspaces } ],
      [ "Scorers",       :scorers_path,               { key: :scorers } ],
      [ "Proposals",     :improvement_proposals_path, { key: :proposals } ],
      [ "Webhooks",      :webhooks_path,              { key: :webhooks } ],
      # No key: the page the switches are on can't be switched off.
      [ "Settings",      :settings_path,              { scope: :harbor } ]
    ].freeze

    def initialize
      @items = DEFAULTS.map do |label, route, opts|
        Item.new(label: label, route: route, scope: opts.fetch(:scope, :main_app), also: opts.fetch(:also, []), key: opts[:key])
      end
    end

    def items = @items.dup

    def labels = @items.map(&:label)

    # Add a page. `after:` / `before:` name an existing label; with neither, the
    # page goes last. `also:` lists extra path prefixes that count as this page.
    # `key:` gives the page a switch on the Settings page, like Harbor's own.
    def add(label, route, after: nil, before: nil, scope: :main_app, also: [], key: nil)
      raise ArgumentError, "#{label.inspect} is already in the menu" if labels.include?(label)
      raise ArgumentError, "give after: or before:, not both" if after && before

      Pages.declare(key, label: label) if key
      item = Item.new(label: label, route: route, scope: scope, also: Array(also), key: key&.to_sym)
      anchor = after || before
      if anchor
        index = labels.index(anchor) or raise ArgumentError, "no menu entry named #{anchor.inspect}"
        @items.insert(after ? index + 1 : index, item)
      else
        @items << item
      end
      item
    end

    def remove(label)
      @items.reject! { |item| item.label == label }
    end

    # The menu for one request: each item's path and whether the current page
    # is under it. An item whose route doesn't exist is left out, so a host
    # shows only the pages it has, and so is one the site has switched off.
    def links(view)
      current = view.request.path
      off = Pages.switched_off(@items.filter_map(&:key))
      @items.filter_map do |item|
        next if off.include?(item.key)

        routes = view.public_send(item.scope)
        next unless routes.respond_to?(item.route)

        path = routes.public_send(item.route)
        active = [ path, *item.also ].any? { |prefix| under?(current, prefix) }
        Link.new(label: item.label, path: path, active: active)
      end
    end

    private
      # "/runs" covers "/runs" and "/runs/12", not "/runsheet".
      def under?(current, prefix)
        current == prefix || current.start_with?("#{prefix.chomp('/')}/")
      end
  end
end
