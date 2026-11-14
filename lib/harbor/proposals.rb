module Harbor
  # What a proposal can change. Harbor's own targets are an agent's system
  # prompt and an agent's document: text it holds, shown as a diff and written
  # with a click. A host adds targets of its own, such as a file in a
  # repository, changed by something the host does:
  #
  #   Harbor::Proposals.register_target "handbook_page",
  #     label: ->(proposal) { "handbook · #{proposal.document_path}" },
  #     build: ->(entry, draft) { { document_path: entry["path"], after: entry["after"] } if entry["after"].present? }
  #
  # label: what the target is called on the pages: text, or a callable given
  # the proposal. build: called when a drafting run proposes this target, with
  # its entry (a Hash, as the run wrote it) and the draft it belongs to
  # (Harbor::Proposals::Recorder::Draft); returns the proposal's attributes
  # beyond scorer, agent, run, target and summary, or nil to record nothing.
  # A target with no `build` is only ever recorded by the host itself.
  module Proposals
    Target = Struct.new(:kind, :label, :build, keyword_init: true)

    AGENT_TARGETS = %w[agent_prompt agent_document].freeze

    # How many failed runs one drafting run is shown, which is how many a
    # check hands over at once: nothing is marked reviewed unseen.
    BATCH = 25

    class << self
      def register_target(kind, label: nil, build: nil)
        kind = kind.to_s
        raise ArgumentError, "#{kind} is one of Harbor's own targets" if AGENT_TARGETS.include?(kind)
        raise ArgumentError, "proposal target #{kind} is already registered" if targets.key?(kind)

        targets[kind] = Target.new(kind:, label:, build:)
      end

      # A host's target, or nil for one of Harbor's own or an unknown one.
      def target(kind) = targets[kind.to_s]

      def target_kinds = AGENT_TARGETS + targets.keys

      # Tests only.
      def reset! = targets.clear

      private
        def targets = (@targets ||= {})
    end
  end
end
