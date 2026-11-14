module Harbor
  module Runtimes
    # The code behind a runtime: where a workspace is made, how an agent runs
    # in it, and how it goes away. Class methods say what a backend can do
    # (they need no row, so choosing a model can ask them); an instance acts
    # for one Harbor::Runtime row. A backend subclasses this and is registered
    # by name (Harbor::Runtimes.register).
    class Backend
      # A backend whose integration isn't built yet. Placement treats it as
      # "skip and say so", never as a failure.
      class NotBuilt < StandardError; end

      class << self
        def label = name.demodulize.titleize

        # Can this backend run `choice` (a model choice) under the agent's
        # tool policy?
        def supports?(choice, allowed_tools: nil, disallowed_tools: nil) = true

        # Added to an "unavailable" message when a policy, not usage, rules
        # every choice out.
        def policy_hint(allowed_tools: nil, disallowed_tools: nil) = nil

        # Whether an agent's tool allow and deny rules are enforced here. Work
        # that needs that guarantee only runs where this is true.
        def enforces_tool_policy? = false

        # Workspaces outlive a run here, so follow-up work goes back to the
        # runtime holding them.
        def keeps_workspaces? = false

        # What this backend reads from a runtime's config, in a sentence or
        # two, for whoever is filling the form in. nil: nothing to say.
        def config_help = nil

        # A config to start from, as the form's placeholder.
        def config_example = {}

        def capabilities = { enforces_tool_policy: enforces_tool_policy?, keeps_workspaces: keeps_workspaces? }

        # Whether the "New runtime" page offers this backend. A backend a
        # host keeps only for the runtimes it already has says false; those
        # runtimes are still shown and edited.
        def offered? = true

        # What the runtime form offers for this backend, registered as
        # `name`: usually one kind of runtime, sometimes more (Orca: on this
        # server, or on a host it reaches).
        def choices(name) = [ Harbor::Runtimes::Choice.new(value: name, backend: name, label: label, description: nil) ]

        # The partial with this backend's own fields on the runtime form, or
        # nil for the plain ones (a host label and the config as JSON). It is
        # rendered once for each choice, with `runtime`, `choice` and
        # `prefix` (the fields' name prefix).
        def fields_partial = nil

        # The runtime's `config` and `host`, from what the form sent for
        # `choice`. Raises ArgumentError with what is wrong.
        def settings_from(fields, choice:, **)
          { "config" => Harbor::Runtimes.parse_config(fields[:config]), "host" => fields[:host].to_s.strip.presence }
        end
      end

      attr_reader :runtime, :options

      # `options` are whatever the caller hands every backend it builds (a
      # client it already holds, say); a backend takes what it knows.
      def initialize(runtime, **options)
        @runtime = runtime
        @options = options
      end

      # Why this runtime can't take new work, found without touching the
      # network (missing configuration, an unbuilt integration), or nil.
      def unready_reason = nil

      # A live probe, for the "Check" button. Raises when unhealthy.
      def health_check = raise(NotImplementedError)

      # Configuration problems worth showing that don't stop placement.
      def warnings = []

      def runner_name = runtime.host.presence || runtime.name

      # What kind of runtime this one is, in a word or two, and which of its
      # backend's choices it is.
      def label = self.class.label
      def choice_value = runtime.backend

      # Where the work happens, as the runtimes page says it.
      def place = runtime.host.presence
    end
  end
end
