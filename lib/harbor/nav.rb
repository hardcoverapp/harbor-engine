module Harbor
  # The section menu: one ordered list that the host's layout (desktop dropdown,
  # mobile sidebar) and the tabs above each page all render, so a page is added
  # or renamed in one place.
  #
  # An item names a route helper instead of a path, so it resolves wherever the
  # engine is mounted. `scope` says whose routes the helper belongs to:
  # `:main_app` for the host's, `:harbor` for the engine's own.
  class Nav
    Item = Struct.new(:label, :route, :scope, :also, keyword_init: true)
    Link = Struct.new(:label, :path, :active, keyword_init: true)

    # Harbor's pages. Their routes still live in the host while the code moves
    # into the engine; an entry switches to `scope: :harbor` when its routes do.
    DEFAULTS = [
      [ "Overview",      :factory_path ],
      [ "Velocity",      :velocity_path ],
      [ "Automations",   :automations_path ],
      [ "Workflows",     :workflows_path ],
      [ "Review policy", :reviews_path ],
      [ "Runs",          :runs_path ],
      [ "Agents",        :agents_path ],
      [ "Models",        :models_path, { also: [ "/model_aliases" ] } ],
      [ "Runtimes",      :runtimes_path ],
      [ "Workspaces",    :workspace_profiles_path ],
      [ "Scorers",       :scorers_path ],
      [ "Proposals",     :improvement_proposals_path ],
      [ "Webhooks",      :webhooks_path ],
      [ "Settings",      :settings_path, { scope: :harbor } ]
    ].freeze

    def initialize
      @items = DEFAULTS.map do |label, route, opts|
        opts ||= {}
        Item.new(label: label, route: route, scope: opts.fetch(:scope, :main_app), also: opts.fetch(:also, []))
      end
    end

    def items = @items.dup

    def labels = @items.map(&:label)

    # Add a page. `after:` / `before:` name an existing label; with neither, the
    # page goes last. `also:` lists extra path prefixes that count as this page.
    def add(label, route, after: nil, before: nil, scope: :main_app, also: [])
      raise ArgumentError, "#{label.inspect} is already in the menu" if labels.include?(label)
      raise ArgumentError, "give after: or before:, not both" if after && before

      item = Item.new(label: label, route: route, scope: scope, also: Array(also))
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
    # is under it.
    def links(view)
      current = view.request.path
      @items.map do |item|
        path = view.public_send(item.scope).public_send(item.route)
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
