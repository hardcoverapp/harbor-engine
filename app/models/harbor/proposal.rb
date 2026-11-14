module Harbor
  # A change proposed by a drafting run, from a batch of one scorer's failures
  # on one agent. Harbor's own targets are text it holds:
  #
  #   agent_prompt     the agent's system prompt
  #   agent_document   one of the agent's documents
  #
  # each with the text before and after, applied here with a click. A host
  # adds targets of its own (Harbor::Proposals.register_target), which Harbor
  # lists and shows and the host acts on.
  #
  # Nothing is adopted without a person: Apply is a button.
  #
  # A host extends it in a subclass named by `config.proposal_class`, as with
  # runs.
  class Proposal < ApplicationRecord
    self.table_name = "improvement_proposals"

    STATUSES = %w[proposed applied dismissed].freeze

    belongs_to :scorer, class_name: Harbor.class_name_for(:scorer_class), optional: true
    belongs_to :agent, class_name: Harbor.class_name_for(:agent_class), foreign_key: :agent_key, primary_key: :key, optional: true
    belongs_to :run, class_name: Harbor.class_name_for(:run_class), optional: true
    has_many :scorer_results, class_name: "Harbor::ScorerResult", foreign_key: :proposal_id, dependent: :nullify, inverse_of: :proposal

    validates :target_kind, inclusion: { in: ->(_) { Harbor::Proposals.target_kinds } }
    validates :status, inclusion: { in: STATUSES }
    validates :summary, presence: true
    validates :document_path, presence: true, if: :agent_document?

    scope :proposed, -> { where(status: "proposed") }
    scope :recent, -> { order(created_at: :desc) }

    def agent_prompt? = target_kind == "agent_prompt"
    def agent_document? = target_kind == "agent_document"
    # One of Harbor's own targets: an agent's text, changed here.
    def agent_target? = Harbor::Proposals::AGENT_TARGETS.include?(target_kind)
    def proposed? = status == "proposed"
    def applicable? = proposed? && agent_target? && agent.present?

    def target_label
      case target_kind
      when "agent_prompt" then "#{agent_key} · system prompt"
      when "agent_document" then "#{agent_key} · #{document_path}"
      else
        label = Harbor::Proposals.target(target_kind)&.label
        (label.respond_to?(:call) ? label.call(self) : label).presence || target_kind.to_s.humanize
      end
    end

    # The text the proposal would replace, as it is right now.
    def current_text
      return nil if agent.nil?
      agent_prompt? ? agent.system_prompt.to_s : agent.agent_documents.find_by(path: document_path)&.body.to_s
    end

    def drifted? = agent_target? && current_text != before.to_s

    # The runs whose failures the proposal was drafted from.
    def evidence_runs = Harbor.run_class.where(id: Array(evidence["run_ids"])).order(:id)

    # Who applied it, as the page says it; nil when it isn't known. Harbor
    # keeps the host's user id (`applied_by_user_id`) and has no user to ask:
    # a host's subclass names them.
    def applied_by_name = nil

    # Write the change onto the agent. Refuses when the target changed since
    # the proposal was made: the drafting run would need to look again.
    def apply!(by:)
      raise ArgumentError, "only agent prompt or document proposals apply here" unless applicable?
      agent.with_lock do
        raise ArgumentError, "#{target_label} changed since this proposal was made — dismiss it and run the check again" if drifted?
        if agent_prompt?
          agent.update!(system_prompt: after)
        else
          doc = agent.agent_documents.find_or_initialize_by(path: document_path)
          doc.update!(body: after)
        end
        update!(status: "applied", applied_by_user_id: by.try(:id), applied_at: Time.current)
      end
      self
    end

    def dismiss!
      update!(status: "dismissed", dismissed_at: Time.current)
    end
  end
end
