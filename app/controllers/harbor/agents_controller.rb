module Harbor
  # The agents: the list with its task routing, shared context and identities tabs, an
  # agent's own page, and the form that creates and edits one.
  class AgentsController < ApplicationController
    # Pages outside this one show agents' avatars, so they stay reachable
    # while it is switched off.
    harbor_page :agents, except: :avatar
    helper Harbor::AgentsHelper
    before_action :set_agent, only: %i[show edit update avatar]

    TABS = %w[agents routing context identities].freeze
    # The form's JSON fields, with what each is when left empty.
    JSON_FIELDS = { "configuration" => {}, "tools" => {}, "default_tasks" => [] }.freeze

    # Four tabs: the agents, which agent takes which task, what every agent
    # is told, and the accounts agents act as. Each loads only what it shows.
    def index
      @tab = (params[:tab].presence_in(TABS) || "agents").to_sym
      case @tab
      when :agents
        @agents = Harbor.agent_class.includes(:model_alias, :workspace_profile, :identity).order(enabled: :desc, key: :asc)
      when :routing
        @assignments = Harbor::TaskTypes.keys.index_with { |type| Harbor.task_assignment_class.find_by(task_type: type) }
      when :context
        @house_context = Harbor::AgentSetting.find_by(key: Harbor::AgentSetting::HOUSE_CONTEXT)&.body
        @shared_documents = Harbor::AgentSetting.shared_documents
      when :identities
        @identities = Harbor::Identity.by_name.includes(:agents)
      end
    end

    def show; end
    def edit; end
    def new = @agent = Harbor.agent_class.new

    # The stored image. Its address carries when the agent last changed, so a
    # browser asks again only to be told nothing has.
    def avatar
      return head :not_found unless @agent.avatar?
      return unless stale?(@agent, public: false)

      send_data @agent.avatar_data, type: @agent.avatar_content_type, disposition: "inline"
    end

    def create
      @agent = Harbor.agent_class.new
      save_agent(:new)
    end

    def update
      save_agent(:edit)
    end

    # What every agent is told: the house context, or one shared document.
    def context
      key = params[:key].presence || Harbor::AgentSetting::HOUSE_CONTEXT
      return head :unprocessable_entity unless Harbor::AgentSetting.editable_key?(key)

      Harbor::AgentSetting.find_or_initialize_by(key:).update!(body: params[:body])
      redirect_to agents_path(tab: "context"), notice: "Shared context updated for new runs."
    end

    private

    def set_agent = @agent = Harbor.agent_class.find(params[:id])

    def save_agent(template)
      attrs = agent_params
      # An agent's key is what everything else names it by: set once.
      attrs.delete("key") if @agent.persisted?
      JSON_FIELDS.each do |field, empty|
        attrs[field] = JSON.parse(params[:agent][field].presence || empty.to_json)
        next if attrs[field].is_a?(empty.class)
        raise ArgumentError, "#{field.humanize} must be a JSON #{empty.is_a?(Array) ? 'array' : 'object'}."
      end
      @agent.assign_attributes(attrs)
      Harbor.config.agent_edited&.call(@agent, harbor_current_user)
      # An agent with no model alias can't run.
      @agent.errors.add(:model_alias, "must be selected") if @agent.model_alias.nil?
      if @agent.model_alias && @agent.save
        redirect_to agent_path(@agent), notice: "Agent saved. Changes apply to new runs."
      else
        render template, status: :unprocessable_entity
      end
    rescue JSON::ParserError, ArgumentError => e
      # The rest of what was typed stays in the form, and the JSON fields
      # show what was typed (the form reads them from the request).
      @agent.assign_attributes(attrs.except(*JSON_FIELDS.keys))
      @agent.errors.add(:base, e.message)
      render template, status: :unprocessable_entity
    end

    # The host's own attributes come before Harbor's, so where one of them
    # sets something a field of Harbor's also sets, the field wins.
    def agent_params
      params.require(:agent).permit(:key, :name, :description, *Harbor.config.agent_params,
        :workspace_profile_id, :identity_id, :max_workspaces, :max_agents, :enabled, :model_alias_id, :system_prompt,
        :avatar, :remove_avatar, agent_documents_attributes: %i[id path body _destroy]).to_h
    end
  end
end
