module Harbor
  # What a site declares about its automations (Harbor::Automation). All of it
  # is optional: a site that declares nothing gets automations that run an
  # agent on a schedule or by hand, in one ungrouped list.
  #
  #   # config/initializers/harbor.rb
  #   Harbor::Automations.category "data", label: "Data"
  #   Harbor::Automations.category "upkeep", label: "Upkeep"
  #   Harbor::Automations.working_folder "app", label: "The app's checkout", path: -> { Rails.root.to_s }
  #   Harbor::Automations.identity "release-bot", label: "@release-bot"
  #   Harbor::Automations.label :run_as, "GitHub identity"
  #   Harbor::Automations.trigger "github", label: "On a GitHub event", kinds: %w[agent]
  #
  # category        a heading the list groups automations under, in the order
  #                 declared. With any declared, every automation has one.
  # working_folder  a folder an agent automation may be told to work in
  #                 (`automation.cwd`). Harbor's own agent sessions work in a
  #                 worktree on their runtime and don't read it; it is for a
  #                 host that runs agent automations its own way.
  # identity        who an agent automation may run as (`automation.run_as`,
  #                 and the run's `acting_as`, which `config.agent_session_env`
  #                 reads to hand a session that identity's credentials).
  # label           what the form calls the working folder (`:cwd_key`) or the
  #                 identity (`:run_as`) field.
  # trigger         a way of starting an automation beyond Harbor's two (a
  #                 schedule, by hand). The host matches and fires it; Harbor
  #                 offers it on the form for the kinds named and accepts it.
  module Automations
    Category = Struct.new(:key, :label, keyword_init: true)
    Trigger = Struct.new(:key, :label, :kinds, keyword_init: true)
    Folder = Struct.new(:key, :label, :path, keyword_init: true) do
      # The folder itself: `path` is a value, or a callable read when asked.
      def location = path.respond_to?(:call) ? path.call : path
    end
    Identity = Struct.new(:key, :label, keyword_init: true)

    # The kinds of automation: one that enqueues a job class of the site's,
    # and one that runs an agent.
    KINDS = %w[job agent].freeze
    # What starts an automation with no trigger of the host's.
    TRIGGERS = %w[schedule manual].freeze
    LABELS = { cwd_key: "Working directory", run_as: "Runs as" }.freeze

    class << self
      def category(key, label: nil)
        add(categories_by_key, Category.new(key: key.to_s, label: label || key.to_s.humanize), "category")
      end

      def working_folder(key, label: nil, path: nil)
        add(folders_by_key, Folder.new(key: key.to_s, label: label || key.to_s, path: path), "working folder")
      end

      def identity(key, label: nil)
        add(identities_by_key, Identity.new(key: key.to_s, label: label || key.to_s), "identity")
      end

      def trigger(key, label:, kinds: KINDS)
        raise ArgumentError, "#{key} is one of Harbor's own triggers" if TRIGGERS.include?(key.to_s)
        add(triggers_by_key, Trigger.new(key: key.to_s, label: label, kinds: Array(kinds).map(&:to_s)), "trigger")
      end

      def label(field, text = nil)
        field = field.to_sym
        raise ArgumentError, "no label named #{field}; there are #{LABELS.keys.join(' and ')}" unless LABELS.key?(field)
        labels[field] = text if text
        labels.fetch(field) { LABELS.fetch(field) }
      end

      # Each in the order declared.
      def categories = categories_by_key.values
      def working_folders = folders_by_key.values
      def identities = identities_by_key.values
      def triggers = triggers_by_key.values

      def find_category(key) = categories_by_key[key.to_s]
      def find_working_folder(key) = folders_by_key[key.to_s]
      def find_identity(key) = identities_by_key[key.to_s]
      def find_trigger(key) = triggers_by_key[key.to_s]

      # Every trigger kind an automation may have: Harbor's and the host's.
      def trigger_kinds = TRIGGERS + triggers_by_key.keys

      # Tests only.
      def reset!
        [ categories_by_key, folders_by_key, identities_by_key, triggers_by_key, labels ].each(&:clear)
      end

      private
        def add(registry, entry, what)
          raise ArgumentError, "#{what} #{entry.key} is already declared" if registry.key?(entry.key)
          registry[entry.key] = entry
        end

        def categories_by_key = (@categories ||= {})
        def folders_by_key = (@folders ||= {})
        def identities_by_key = (@identities ||= {})
        def triggers_by_key = (@triggers ||= {})
        def labels = (@labels ||= {})
    end
  end
end
