module Harbor
  module AgentSession
    # What codex can enforce of an agent's tool rules. It has no per-tool
    # allow list: an allow list of only reading tools maps to its read-only
    # sandbox, and a deny list maps to switches it has. Anything else it
    # cannot keep, so the work must not be given to it: placement asks here
    # before choosing an OpenAI model, and Command refuses to build the
    # command (it fails closed instead of running with weaker rules).
    module ToolPolicy
      # An allow list of only these runs in codex's read-only sandbox.
      READ_ONLY_TOOLS = %w[Read Grep Glob].freeze
      # Denying any of these has a codex equivalent.
      CODEX_DISALLOWED_TOOLS = %w[Edit Write NotebookEdit Bash Agent Task].freeze
      # Denying one of these means the session must not change files.
      WRITING_TOOLS = %w[Edit Write NotebookEdit].freeze

      module_function

      def codex_supported?(allowed_tools: nil, disallowed_tools: nil)
        (Array(allowed_tools) - READ_ONLY_TOOLS).empty? && (Array(disallowed_tools) - CODEX_DISALLOWED_TOOLS).empty?
      end
    end
  end
end
