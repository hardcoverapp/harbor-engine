module Harbor
  # What the Agents pages need beyond drawing an agent (Harbor::AgentHelper).
  module AgentsHelper
    # Whether the host has a partial of its own for a place on these pages
    # (app/views/harbor/agents/_<name>.html.erb in the host).
    def harbor_agents_partial?(name) = lookup_context.exists?("harbor/agents/#{name}", [], true)

    # A JSON field of the agent form: what was just typed, when the form is
    # being shown again after a mistake, else the saved value.
    def harbor_agent_json(agent, field)
      params.dig(:agent, field) || JSON.pretty_generate(agent.public_send(field))
    end
  end
end
