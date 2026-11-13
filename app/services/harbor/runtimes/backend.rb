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
    end
  end
end
