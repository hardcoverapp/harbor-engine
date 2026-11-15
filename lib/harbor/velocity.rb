require "active_support"
require "active_support/core_ext/integer/time"
require "active_support/core_ext/numeric/time"

module Harbor
  # Velocity: how much work ran over a period, how it ended and what it cost.
  # Three tabs of Harbor's own, each read from its records: Runs (how many,
  # how they ended, by agent, by task type, by runtime), Spending (by week,
  # by agent, by model) and Scorers (each scorer's pass rate and what the
  # judging cost).
  #
  # A host adds tabs and tiles of its own, and takes away a tab it replaces:
  #
  #   # config/initializers/harbor.rb
  #   Harbor::Velocity.tab "tickets", label: "Tickets", partial: "velocity/tickets", before: "runs"
  #   Harbor::Velocity.remove_tab "runs"
  #   Harbor::Velocity.tile("spending", :per_ticket, label: "Per ticket", note: "median", after: :runs) do |period|
  #     "$%.2f" % Ticket.median_cost(period.range)
  #   end
  #
  # tab   a tab of the host's: its partial is rendered with `period`
  #       (Harbor::Velocity::Period: since, now, range).
  # tile  a number in the row at the top of a tab. The block is given the
  #       period and returns what the tile shows.
  module Velocity
    RANGES = {
      "7d"  => [ "Last 7 days", 7.days ],
      "30d" => [ "Last 30 days", 30.days ],
      "90d" => [ "Last 90 days", 90.days ],
      "12w" => [ "Last 12 weeks", 12.weeks ],
      "6m"  => [ "Last 6 months", 6.months ]
    }.freeze
    DEFAULT_RANGE = "12w".freeze

    Tab = Struct.new(:key, :label, :partial, keyword_init: true)
    Tile = Struct.new(:key, :label, :value, :note, :wide, :after, :block, keyword_init: true)

    # The period a page is about. `fetch` keeps something built for it once
    # per page, for a host whose tile and section read the same figures.
    class Period
      attr_reader :since, :now

      def initialize(since:, now: Time.current)
        @since = since
        @now = now
        @kept = {}
      end

      def range = since..now

      def fetch(key) = @kept.fetch(key) { @kept[key] = yield }
    end

    TABS = [ %w[runs Runs], %w[spending Spending], %w[scorers Scorers] ].freeze

    class << self
      def tab(key, label:, partial:, before: nil, after: nil)
        raise ArgumentError, "give before: or after:, not both" if before && after
        anchor = (before || after)&.to_s
        list = tab_list
        list.reject! { |tab| tab.key == key.to_s }
        index = anchor && (list.index { |tab| tab.key == anchor } or raise ArgumentError, "no Velocity tab named #{anchor}")
        list.insert(index ? (after ? index + 1 : index) : list.size, Tab.new(key: key.to_s, label:, partial:))
      end

      def remove_tab(key) = tab_list.reject! { |tab| tab.key == key.to_s }

      def tabs = tab_list.dup

      def tile(tab, key, label:, note: nil, after: nil, wide: false, &block)
        (tile_list[tab.to_s] ||= {})[key.to_sym] = Tile.new(key: key.to_sym, label:, note:, after: after&.to_sym, wide:, block:)
      end

      def tiles(tab) = (tile_list[tab.to_s] || {}).values

      # Tests only: what is declared, to put back afterwards.
      def snapshot = { tab_list: tab_list.dup, tile_list: tile_list.transform_values(&:dup) }

      def restore!(snapshot)
        @tab_list = snapshot[:tab_list].dup
        @tile_list = snapshot[:tile_list].transform_values(&:dup)
      end

      def reset!
        @tab_list = nil
        @tile_list = nil
      end

      private
        def tab_list = @tab_list ||= TABS.map { |key, label| Tab.new(key:, label:, partial: "harbor/velocity/#{key}") }
        def tile_list = @tile_list ||= {}
    end
  end
end
