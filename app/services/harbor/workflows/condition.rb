module Harbor
  module Workflows
    # Structured conditions: data a form can edit, never code. A leaf reads
    # one context path:
    #
    #   { "path": "steps.review.verdict", "op": "in", "values": ["changes", "comment"] }
    #
    # and leaves combine with { "all": [...] }, { "any": [...] }, { "not": {...} }.
    module Condition
      OPS = %w[eq ne in not_in contains present blank gt gte lt lte].freeze

      module_function

      def evaluate(cond, context)
        return true if cond.blank?
        cond = cond.to_h
        return Array(cond["all"]).all? { |c| evaluate(c, context) } if cond.key?("all")
        return Array(cond["any"]).any? { |c| evaluate(c, context) } if cond.key?("any")
        return !evaluate(cond["not"], context) if cond.key?("not")

        actual = context.dig_path(cond["path"])
        wanted = cond.key?("values") ? Array(cond["values"]) : cond["value"]
        case cond["op"]
        when "eq"       then same?(actual, wanted)
        when "ne"       then !same?(actual, wanted)
        when "in"       then Array(wanted).any? { |w| same?(actual, w) }
        when "not_in"   then Array(wanted).none? { |w| same?(actual, w) }
        when "contains" then actual.is_a?(Array) ? actual.any? { |a| same?(a, wanted) } : actual.to_s.downcase.include?(wanted.to_s.downcase)
        when "present"  then actual.present? || actual == false
        when "blank"    then actual.blank? && actual != false
        when "gt"       then num(actual) > num(wanted)
        when "gte"      then num(actual) >= num(wanted)
        when "lt"       then num(actual) < num(wanted)
        when "lte"      then num(actual) <= num(wanted)
        else false
        end
      end

      # Strings compare case-insensitively ("APPROVED" from a webhook vs approved).
      def same?(a, b)
        return a.to_s.casecmp?(b.to_s) if a.is_a?(String) || b.is_a?(String)
        a == b
      end

      def num(v) = v.to_f

      def validate(cond, errors = [])
        return errors if cond.nil?
        unless cond.is_a?(Hash)
          errors << "a condition must be an object"
          return errors
        end
        if cond.key?("all") || cond.key?("any")
          list = cond["all"] || cond["any"]
          errors << "all/any takes a list" unless list.is_a?(Array)
          Array(list).each { |c| validate(c, errors) }
        elsif cond.key?("not")
          validate(cond["not"], errors)
        else
          errors << "a condition needs a path" if cond["path"].blank?
          errors << "op must be one of #{OPS.join(', ')}" unless OPS.include?(cond["op"])
        end
        errors
      end

      # "steps.review.verdict in changes, comment" — for the graph and the run page.
      def describe(cond)
        return "always" if cond.blank?
        return Array(cond["all"]).map { |c| describe(c) }.join(" and ") if cond.key?("all")
        return "(#{Array(cond['any']).map { |c| describe(c) }.join(' or ')})" if cond.key?("any")
        return "not #{describe(cond['not'])}" if cond.key?("not")
        value = cond.key?("values") ? Array(cond["values"]).join(", ") : cond["value"].to_s
        [ cond["path"], cond["op"].to_s.tr("_", " "), value.presence ].compact.join(" ")
      end
    end
  end
end
