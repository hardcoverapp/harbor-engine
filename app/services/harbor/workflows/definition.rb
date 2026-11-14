module Harbor
  module Workflows
    # A workflow's definition: JSON with triggers, settings, steps and finally
    # steps. Steps nest (choice branches, loop bodies), so the graph is a tree
    # read top to bottom, the way the builder and the run page draw it.
    #
    #   {
    #     "settings": { … },
    #     "inputs":   [ { "key": "branch" } ],
    #     "triggers": [ { "kind": "manual" } ],
    #     "steps":    [ { "key": "review", "type": "verifier", "agent": "…", "prompt": "Review {{input.branch}}",
    #                     "verdicts": [ "approve", "changes" ] }, … ],
    #     "finally":  [ { "key": "done", "type": "action", "action": "note", "message": "{{steps.review.verdict}}" } ]
    #   }
    #
    # Validation runs on save, before a version exists: a graph that can't
    # finish never gets admitted. Which step types and triggers exist, and
    # what each asks of a step, is what is registered (Harbor::Workflows).
    class Definition
      CONTAINERS = %w[choice loop].freeze
      MAX_LOOP = Harbor::Workflows::MAX_LOOP
      KEY = /\A[a-z][a-z0-9_]*\z/

      attr_reader :data, :errors

      def self.parse(json_or_hash)
        data = json_or_hash.is_a?(String) ? JSON.parse(json_or_hash) : json_or_hash.to_h
        new(data.deep_stringify_keys)
      rescue JSON::ParserError => e
        d = new({})
        d.errors << "Not valid JSON: #{e.message.lines.first.strip}"
        d
      end

      def initialize(data)
        @data = data
        @errors = []
      end

      def settings = data["settings"].to_h
      def triggers = Array(data["triggers"])
      def steps = Array(data["steps"])
      def finally_steps = Array(data["finally"])
      # What a called workflow expects as input.* (for the builder's data picker).
      def inputs = Array(data["inputs"])

      # Every step at any depth, with the path of containers above it.
      def each_step(list = steps + finally_steps, parents = [], &block)
        return enum_for(:each_step, list, parents) unless block
        list.each do |step|
          yield step, parents
          children_of(step).each { |child_list| each_step(child_list, parents + [ step ], &block) }
        end
      end

      def children_of(step)
        case step["type"]
        when "choice" then Array(step["branches"]).map { |b| Array(b["steps"]) } + [ Array(step["otherwise"]) ]
        when "loop"   then [ Array(step["steps"]) ]
        else []
        end
      end

      def find(key) = each_step.find { |s, _| s["key"] == key }&.first

      def valid?
        validate
        errors.empty?
      end

      def validate
        return errors if errors.any? # already a parse error
        errors << "Give at least one trigger" if triggers.empty?
        errors << "Give at least one step" if steps.empty?
        inputs.each_with_index do |i, n|
          errors << "Input #{n + 1}: name must be lowercase letters, digits and _" unless i.is_a?(Hash) && i["key"].to_s.match?(KEY)
        end
        triggers.each_with_index { |t, i| validate_trigger(t, i) }

        seen = {}
        each_step do |step, parents|
          key = step["key"].to_s
          label = key.presence || "(unnamed #{step['type']})"
          unless key.match?(KEY)
            errors << "#{label}: key must be lowercase letters, digits and _ (starting with a letter)"
          end
          errors << "#{label}: key is used twice" if seen[key]
          seen[key] = true
          validate_step(step, label, parents)
        end
        Harbor::Workflows.validator_entries.each { |validator| errors.concat(Array(validator.call(self))) }
        validate_templates(seen)
        errors
      end

      private

      def validate_trigger(t, i)
        label = "Trigger #{i + 1}"
        kinds = Harbor::Workflows.trigger_kinds
        entry = Harbor::Workflows.trigger(t["kind"])
        return errors << "#{label}: kind must be one of #{kinds.join(', ')}" unless entry
        errors.concat(Array(entry.validate.call(t, label))) if entry.validate
        validate_condition(t["conditions"], label) if t["conditions"]
      end

      def validate_step(step, label, parents)
        type = step["type"].to_s
        types = Harbor::Workflows.step_types
        return errors << "#{label}: type must be one of #{types.join(', ')}" unless types.include?(type)
        entry = Harbor::Workflows.step_for(step)
        if entry.nil?
          # The type is known, so it is one told apart by its action.
          errors << "#{label}: action must be one of #{Harbor::Workflows.actions.join(', ')}"
        elsif entry.validate
          errors.concat(Array(entry.validate.call(step, label)))
        end
        if parents.any? { |p| p["type"] == "loop" } && entry && !entry.inside_loop
          errors << "#{label}: #{type} can't sit inside a loop"
        end
      end

      # A template may only read the outputs of steps that exist.
      def validate_templates(keys)
        paths = []
        each_step do |step, _|
          %w[prompt slash_command body].each { |f| paths.concat(step[f].to_s.scan(/\{\{\s*steps\.([a-z0-9_]+)/).flatten) }
        end
        (paths.uniq - keys.keys).each { |missing| errors << "A template reads steps.#{missing}, but there's no step with that key" }
      end

      def validate_condition(cond, label)
        Condition.validate(cond).each { |e| errors << "#{label}: #{e}" }
      end
    end
  end
end
