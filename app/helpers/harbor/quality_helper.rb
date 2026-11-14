module Harbor
  # What the Scorers and Proposals pages need.
  module QualityHelper
    # Whether the host has a partial of its own for a place on the Scorers
    # pages (app/views/harbor/scorers/_<name>.html.erb in the host).
    def harbor_scorers_partial?(name) = lookup_context.exists?("harbor/scorers/#{name}", [], true)

    # The same for the Proposals pages (app/views/harbor/proposals/).
    def harbor_proposals_partial?(name) = lookup_context.exists?("harbor/proposals/#{name}", [], true)
  end
end
