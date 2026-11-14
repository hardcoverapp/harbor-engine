module Harbor
  module Workflows
    # One flat context per workflow run:
    #
    #   trigger.*   what started it, as the host normalized it
    #   input.*     manual or `call` input
    #   settings.*  the workflow's settings
    #   steps.<key>.*            the latest output of each step
    #   steps.<key>.iterations   every pass's output for steps inside loops
    #   run.*       id, url, and what the run is about
    #
    # Prompts are templates over it ({{steps.review.feedback}}); conditions
    # read it by path. Unknown placeholders stay as written so a typo shows.
    class Context
      PLACEHOLDER = /\{\{\s*([a-zA-Z0-9_.\-]+)\s*\}\}/

      attr_reader :data

      def initialize(data = {})
        @data = data.deep_stringify_keys
        @data["steps"] ||= {}
      end

      def record(key, output, iteration: nil)
        out = output.to_h.deep_stringify_keys
        prev = data["steps"][key]
        iterations = Array(prev&.dig("iterations"))
        iterations += [ out.merge("iteration" => iteration) ] if iteration
        data["steps"][key] = iteration ? out.merge("iterations" => iterations) : out
      end

      def dig_path(path)
        path.to_s.split(".").reduce(data) do |node, part|
          case node
          when Hash  then node[part]
          when Array then part.match?(/\A-?\d+\z/) ? node[part.to_i] : nil
          end
        end
      end

      def render(text)
        return text if text.blank?
        text.to_s.gsub(PLACEHOLDER) do
          value = dig_path(Regexp.last_match(1))
          value.nil? ? Regexp.last_match(0) : (value.is_a?(Hash) || value.is_a?(Array) ? value.to_json : value.to_s)
        end
      end

      # Render every string inside a step's config (for "resolved input").
      def render_deep(obj)
        case obj
        when String then render(obj)
        when Hash   then obj.transform_values { |v| render_deep(v) }
        when Array  then obj.map { |v| render_deep(v) }
        else obj
        end
      end

      # Which steps' outputs a piece of text reads — the run page's "from" links.
      def self.sources(text)
        text.to_s.scan(PLACEHOLDER).flatten.filter_map { |p| p.split(".")[1] if p.start_with?("steps.") }.uniq
      end
    end
  end
end
