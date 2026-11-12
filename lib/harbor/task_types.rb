module Harbor
  # The kinds of work a site hands to agents ("pr_review", "support_draft").
  # Code dispatches by task type, so the types are declared in code, by the
  # host; which agent handles each is data, edited in the app
  # (Harbor::TaskAssignment).
  #
  #   Harbor::TaskTypes.declare "pr_review"
  #   Harbor::TaskTypes.declare "pr_rebase", fallback: "fix_ci"
  #   Harbor::TaskTypes.declare "issue_triage", default_agent: "planner", executor: "bridge"
  #
  # fallback: a task type with no assignment of its own goes to this type's
  # agent. default_agent: with no assignment and no fallback's, the agent with
  # this key. Anything else given is kept in `details` for the host's own use.
  module TaskTypes
    Definition = Struct.new(:key, :fallback, :default_agent, :details, keyword_init: true)

    class Unknown < KeyError; end

    class << self
      def declare(key, fallback: nil, default_agent: nil, **details)
        key = key.to_s
        raise ArgumentError, "task type #{key} is already declared" if definitions.key?(key)

        definitions[key] = Definition.new(key:, fallback: fallback&.to_s, default_agent: default_agent&.to_s, details: details.freeze)
      end

      def find(key)
        definitions.fetch(key.to_s) { raise Unknown, "no task type named #{key}" }
      end

      def declared?(key) = definitions.key?(key.to_s)

      # In the order declared, which is the order the routing table lists them.
      def keys = definitions.keys

      def all = definitions.values

      # Tests only.
      def reset! = definitions.clear

      private
        def definitions = (@definitions ||= {})
    end
  end
end
