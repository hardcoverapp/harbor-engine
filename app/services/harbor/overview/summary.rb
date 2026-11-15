module Harbor
  module Overview
    # "At a glance": one number for each thing Harbor keeps, over the last
    # thirty days where it is a count of what happened. A tile whose page is
    # switched off is left out, and a host's own tiles (Harbor::Overview.tile)
    # sit after the ones they name, or at the end.
    class Summary
      # Each tile: its key, the page whose switch it follows, and what builds it.
      BUILT_IN = [ %i[runs runs runs_tile], %i[spend velocity spend_tile], %i[agents agents agents_tile],
                   %i[workflows workflows workflows_tile], %i[automations automations automations_tile],
                   %i[runtimes runtimes runtimes_tile], %i[scorers scorers scorers_tile],
                   %i[proposals proposals proposals_tile], %i[reviews reviews reviews_tile] ].freeze

      attr_reader :since

      def initialize(since: Harbor::Overview::WINDOW.ago)
        @since = since
      end

      def tiles
        off = Harbor::Pages.switched_off(BUILT_IN.map { |_, page, _| page })
        tiles = BUILT_IN.reject { |_, page, _| off.include?(page) }.map { |key, _, build| send(build).tap { |tile| tile.key = key } }
        Harbor::Overview.tiles.each do |declared|
          shown = declared.block.call(since).to_h
          tile = Tile.new(key: declared.key, label: declared.label, value: shown[:value], note: shown[:note], url: shown[:url])
          index = declared.after && tiles.index { |other| other.key == declared.after }
          tiles.insert(index ? index + 1 : tiles.size, tile)
        end
        tiles
      end

      private
        def routes = Harbor::Engine.routes.url_helpers

        def runs = Harbor.run_class.where(created_at: since..)

        def runs_tile
          failed = runs.where(status: %w[error timeout]).count
          active = Harbor.run_class.queued_or_running.count
          Tile.new(label: "Runs", value: runs.count, note: "#{failed} failed · #{active} under way now", url: routes.runs_path)
        end

        def spend_tile
          spending = Harbor::Velocity::Spending.new(since:)
          Tile.new(label: "Spend", value: format("$%.2f", spending.total),
                   note: "#{spending.costed_count} #{'run'.pluralize(spending.costed_count)} with a cost",
                   url: routes.velocity_path(tab: "spending", range: "30d"))
        end

        def agents_tile
          counts = Harbor.agent_class.group(:enabled).count
          Tile.new(label: "Agents", value: counts[true].to_i, note: "#{counts[false].to_i} switched off", url: routes.agents_path)
        end

        def workflows_tile
          modes = Harbor.workflow_class.group(:mode).count
          Tile.new(label: "Workflows", value: modes["live"].to_i, note: "live · #{modes['dry_run'].to_i} in dry run · #{modes['off'].to_i} off",
                   url: routes.workflows_path)
        end

        def automations_tile
          counts = Harbor.automation_class.group(:enabled).count
          Tile.new(label: "Automations", value: counts[true].to_i, note: "on · #{counts[false].to_i} off", url: routes.automations_path)
        end

        def runtimes_tile
          counts = Harbor.runtime_class.group(:enabled).count
          Tile.new(label: "Runtimes", value: counts[true].to_i, note: "on · #{counts[false].to_i} off", url: routes.runtimes_path)
        end

        def scorers_tile
          results = Harbor::ScorerResult.scored.where(scored_at: since..)
          judged = results.count
          rate = judged.zero? ? "—" : "#{(100.0 * results.where(passed: true).count / judged).round}%"
          Tile.new(label: "Scorers", value: rate, note: "of #{judged} judged runs passed", url: routes.scorers_path)
        end

        def proposals_tile
          Tile.new(label: "Proposals", value: Harbor.proposal_class.proposed.count, note: "waiting for a person", url: routes.proposals_path)
        end

        def reviews_tile
          rounds = Harbor::ReviewRound.where(created_at: since.., dry_run: false)
          pull_requests = rounds.distinct.count(:pr_number)
          Tile.new(label: "Review rounds", value: rounds.count, note: "on #{pull_requests} #{'pull request'.pluralize(pull_requests)}",
                   url: routes.reviews_path)
        end
    end
  end
end
