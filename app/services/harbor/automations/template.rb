module Harbor
  module Automations
    # {{placeholders}} in an agent automation's instructions or slash command,
    # filled from what started the run (a webhook's subject, mostly). Unknown
    # placeholders are left as written, so a typo shows in the run's command
    # instead of going silently blank.
    module Template
      PLACEHOLDER = /\{\{\s*([a-z_]+)\s*\}\}/

      module_function

      def render(text, context)
        return text if text.blank?
        ctx = (context || {}).to_h.transform_keys(&:to_s)
        text.gsub(PLACEHOLDER) do
          key = Regexp.last_match(1)
          ctx.key?(key) ? ctx[key].to_s : Regexp.last_match(0)
        end
      end
    end
  end
end
