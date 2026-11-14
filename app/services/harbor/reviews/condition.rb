module Harbor
  module Reviews
    # The conditions a rule is written in: data a form can edit, never code.
    # A leaf reads one path:
    #
    #   { "path": "outputs.pages_over", "op": "blank" }
    #
    # and leaves combine with { "all": [...] }, { "any": [...] } and
    # { "not": {...} }. This checks one and puts it in words; deciding whether
    # one holds for a check's outputs belongs to whatever runs the check.
    module Condition
      OPS = %w[eq ne in not_in contains present blank gt gte lt lte].freeze

      module_function

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

      # "outputs.pages_over blank", "outputs.rollback_ok eq true and …".
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
