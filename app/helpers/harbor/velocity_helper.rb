module Harbor
  # What the Velocity page needs.
  module VelocityHelper
    # Whether the host has a partial of its own for a place on Velocity
    # (app/views/harbor/velocity/_<name>.html.erb in the host).
    def harbor_velocity_partial?(name) = lookup_context.exists?("harbor/velocity/#{name}", [], true)

    # One tile of a tab's top row.
    def harbor_velocity_tile(key, label, value, note = nil, wide: false)
      Harbor::Velocity::Tile.new(key:, label:, value:, note:, wide:)
    end

    # A tab's tiles: Harbor's own, with the host's (Harbor::Velocity.tile)
    # after the ones they name, or at the end.
    def harbor_velocity_tiles(tab, period, own)
      tiles = own.dup
      Harbor::Velocity.tiles(tab).each do |declared|
        tile = Harbor::Velocity::Tile.new(key: declared.key, label: declared.label, value: declared.block.call(period),
                                          note: declared.note, wide: declared.wide)
        index = declared.after && tiles.index { |other| other.key == declared.after }
        tiles.insert(index ? index + 1 : tiles.size, tile)
      end
      tiles
    end
  end
end
