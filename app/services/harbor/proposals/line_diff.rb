module Harbor
  module Proposals
    # Line diff for the proposal page: [[:same | :del | :add, line], ...] by a
    # plain LCS. Big texts fall back to "replace everything" rather than spend
    # the page load on an O(n·m) table.
    module LineDiff
      MAX_LINES = 400

      module_function

      def call(before, after)
        a = before.to_s.lines.map(&:chomp)
        b = after.to_s.lines.map(&:chomp)
        return a.map { |l| [ :del, l ] } + b.map { |l| [ :add, l ] } if a.size > MAX_LINES || b.size > MAX_LINES

        table = Array.new(a.size + 1) { Array.new(b.size + 1, 0) }
        a.size.downto(1) do |i|
          b.size.downto(1) do |j|
            table[i - 1][j - 1] = a[i - 1] == b[j - 1] ? table[i][j] + 1 : [ table[i][j - 1], table[i - 1][j] ].max
          end
        end
        out, i, j = [], 0, 0
        while i < a.size && j < b.size
          if a[i] == b[j]
            out << [ :same, a[i] ]; i += 1; j += 1
          elsif table[i + 1][j] >= table[i][j + 1]
            out << [ :del, a[i] ]; i += 1
          else
            out << [ :add, b[j] ]; j += 1
          end
        end
        out.concat(a[i..].map { |l| [ :del, l ] }).concat(b[j..].map { |l| [ :add, l ] })
      end

      def changed?(diff) = diff.any? { |kind, _| kind != :same }
    end
  end
end
