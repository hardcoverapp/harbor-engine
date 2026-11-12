module Harbor
  module Runtimes
    # Where a run executes, and on which model: WorkspaceProfile#resolve.
    #
    # Walks the workspace's runtimes in order and uses the first that is
    # switched on, healthy, below its limit, and has a usable model choice for
    # the agent there. Runtime and model fall back as one decision. A runtime
    # already holding the run's live workspace (`config.sticky_runtime`) goes
    # first.
    #
    #   preview  ignores limits: what the run would get if it started now
    #   acquire  also takes a runtime slot; the result is #waiting? when every
    #            usable runtime is full, so the run waits its turn
    #
    # Raises the workspace's Unavailable (a model alias's Unavailable, so the
    # run waits for availability instead of failing) only when no runtime in
    # the list could run the agent at all. Every decision carries `notes`
    # ("Cloud: disabled; Laptop: 5/5 busy; using …") for the run's log.
    class Placement
      Result = Struct.new(:runtime, :choice, :slot, :owner, :notes, :sticky, keyword_init: true) do
        def summary = notes.join("; ")
        # Every usable runtime is full: the run waits.
        def waiting? = runtime.nil?
      end

      # A runtime that already holds the workspace a run needs, as
      # `config.sticky_runtime` returns it. `required`: the work can only
      # happen in that workspace, so it waits rather than starting elsewhere.
      Hold = Struct.new(:runtime, :reason, :required, keyword_init: true)

      # requirements: { tool_policy: true } keeps work on runtimes whose
      # backend enforces the agent's tool policy.
      def initialize(profile:, agent:, run: nil, allowed_tools: :agent, disallowed_tools: nil, requirements: {})
        @profile = profile
        @agent = agent
        @run = run
        @allowed_tools = allowed_tools == :agent ? agent&.tools&.dig("allowed") : allowed_tools
        @disallowed_tools = disallowed_tools
        @requirements = requirements || {}
      end

      def preview = place(capacity: nil)

      def acquire(owner:, ttl:, workspace: nil) = place(capacity: { owner:, ttl:, workspace: })

      private

      def unavailable = @profile.class::Unavailable

      def place(capacity:)
        notes = []
        eligible = []
        candidates = @profile.ordered_runtimes
        hold = @run && Harbor.config.sticky_runtime&.call(@run)
        if hold && (hold.required || candidates.include?(hold.runtime))
          reason, choice = check(hold.runtime)
          if reason.nil?
            taken = take(hold.runtime, choice, capacity, notes, sticky: hold)
            return taken if taken
            notes << "#{hold.runtime.name} holds the live workspace (#{hold.reason}): #{hold.runtime.usage_label}"
            return Result.new(notes:, sticky: true)
          end
          if hold.required
            raise unavailable, "#{hold.runtime.name} holds the workspace this run needs (#{hold.reason}), " \
                               "but it is #{reason}. Check /runtimes."
          end
          notes << "#{hold.runtime.name} holds the live workspace but is #{reason}; starting a fresh one"
          candidates -= [ hold.runtime ]
        end

        candidates.each do |runtime|
          reason, choice = check(runtime)
          if reason
            notes << "#{runtime.name}: #{reason}"
            next
          end
          eligible << runtime
          result = take(runtime, choice, capacity, notes)
          return result if result
          notes << "#{runtime.name}: #{runtime.usage_label}"
        end

        if eligible.empty?
          raise unavailable,
                "No runtime in the #{@profile.name} workspace can run #{@agent&.key || 'this agent'}: " \
                "#{notes.join('; ').presence || 'it lists no runtimes'}. Check /runtimes and /models.#{policy_hint}"
        end
        Result.new(notes:, sticky: false)
      end

      # [why it can't run here, or nil; the model choice it would run].
      def check(runtime)
        if (reason = runtime.unavailable_reason)
          return [ reason ]
        end
        if @requirements[:tool_policy] && !runtime.backend_class.enforces_tool_policy?
          return [ "can't enforce this work's tool policy" ]
        end
        return [ nil, nil ] unless @agent

        [ nil, @agent.model_choice_for(backend: runtime.backend_class, allowed_tools: @allowed_tools, disallowed_tools: @disallowed_tools) ]
      rescue Harbor::ModelAlias::Unavailable
        [ "no available model for #{@agent.model_label} here" ]
      end

      def take(runtime, choice, capacity, notes, sticky: nil)
        slot = nil
        if capacity
          slot = Slots.acquire(runtime, capacity[:owner], ttl: capacity[:ttl], workspace: capacity[:workspace]) or return nil
        end
        notes << (sticky ? "using #{runtime.name}, which holds the live workspace (#{sticky.reason})" : "using #{runtime.name}")
        Result.new(runtime:, choice:, slot:, owner: capacity&.dig(:owner), notes:, sticky: !sticky.nil?)
      end

      def policy_hint
        hints = @profile.ordered_runtimes.map { |r| r.backend_class.policy_hint(allowed_tools: @allowed_tools, disallowed_tools: @disallowed_tools) }
        hints.compact.first
      end
    end
  end
end
