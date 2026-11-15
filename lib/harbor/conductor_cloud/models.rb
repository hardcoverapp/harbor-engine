module Harbor
  module ConductorCloud
    # Conductor's API only takes its own model ids ("opus-5-5-1m"), which are
    # not the ids a model alias holds ("claude-opus-5-5"). This is the list of
    # ids Harbor knows Conductor to have, and the rule that finds one for a
    # model.
    #
    # The lists are the `model` enum of https://api.conductor.build/v0/openapi.json
    # as of 2026-11-15, for the two agents Harbor runs (claude and codex),
    # newest first within a family. When Conductor adds a model before Harbor
    # does, a host adds its id: `config.conductor_cloud_models = %w[opus-6-1m]`.
    module Models
      CLAUDE = %w[
        fable-5-2 fable-5-1 fable-5
        opus-5-5-1m opus-5-1m opus-4-8-1m opus-4-8 opus-4-7-1m opus-4-7 opus-4-6-1m
        sonnet-5-5-1m sonnet-5-1m sonnet-4-6-1m sonnet-4-6
        haiku-5-5-1m haiku-4-5
      ].freeze
      OPENAI = %w[
        gpt-6.1-sol gpt-6.1-terra gpt-6-sol gpt-6-luna gpt-6-astra
        gpt-5.6-sol gpt-5.6-terra gpt-5.6-luna gpt-5.5 gpt-5.4
        gpt-5.3-codex-spark gpt-5.3-codex gpt-5.2-codex gpt-daybreak-blue-latest
      ].freeze
      # The reasoning depths Conductor takes; any other is left out.
      EFFORTS = %w[none low medium high xhigh max ultra ultracode].freeze

      module_function

      # Every id known: the host's first, so its newer ones win for an alias.
      def ids = (Array(Harbor.config.conductor_cloud_models).map(&:to_s) + CLAUDE + OPENAI).uniq

      # Conductor's id for a model, or nil when it has none:
      #
      #   an id of Conductor's own          itself
      #   "claude-opus-5-5", "opus-5.5",    the same family and version, with
      #   "claude-opus-5-5-20260301"        its 1M-context variant when there
      #                                     is one ("opus-5-5-1m")
      #   a bare family ("opus")            the first id of that family
      def id_for(model)
        name = model.to_s.strip.downcase
        return nil if name.empty?
        known = ids
        return name if known.include?(name)

        base = name.delete_prefix("claude-").delete_suffix("[1m]").delete_suffix("-1m").sub(/-\d{8}\z/, "").tr(".", "-")
        found = [ "#{base}-1m", base ].find { |id| known.include?(id) }
        found || (known.find { |id| id.start_with?("#{base}-") } if base.match?(/\A[a-z]+\z/))
      end

      def effort_for(effort) = effort.to_s.presence_in(EFFORTS)
    end
  end
end
