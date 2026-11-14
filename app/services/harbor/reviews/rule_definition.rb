module Harbor
  module Reviews
    # What a rule says, per kind, and whether it may be saved. A definition is
    # data a form edits; its conditions are Harbor::Reviews::Condition trees.
    #
    # risk     { label, description, color, detector }
    #          detector: { "builtin" => name }   a detector the site declared
    #                                            (Harbor::Reviews.detector)
    #                  | { "paths" => [regex], "patch" => [regex], "words" => regex }
    # check    { description, mitigates, kind, run, outputs, pass_when, then, gate, stage,
    #            watch_paths, timeout_minutes, needs_workspace, delay_minutes, max_cost_usd }
    # signoff  { who, message, when }
    #          when: { "risks" => [key] } and/or { "paths" => [regex] }; a check's
    #          then-row can also require it ({ "action" => "signoff", "signoff" => key })
    module RuleDefinition
      CHECK_KINDS   = %w[ci command agent].freeze
      GATES         = %w[blocking advisory].freeze
      STAGES        = %w[evidence after_approval after_deploy].freeze
      OUTPUT_TYPES  = %w[bool number string list object].freeze
      ACTIONS       = %w[block note signoff run tell_reviewer].freeze
      PASS_SHORTCUTS = %w[exit_zero ci_success agent_verdict].freeze

      module_function

      def normalize(kind, hash)
        data = JSON.parse(JSON.generate(hash.to_h)) # deep string keys, plain JSON
        return data unless kind == "check"

        data["mitigates"]   = Array(data["mitigates"]).map(&:to_s)
        data["outputs"]     = Array(data["outputs"])
        data["then"]        = Array(data["then"])
        data["watch_paths"] = Array(data["watch_paths"])
        data["gate"]      ||= "blocking"
        data["stage"]     ||= "evidence"
        data["pass_when"] ||= default_pass(data["kind"])
        data
      end

      def default_pass(kind)
        { "ci" => "ci_success", "command" => "exit_zero", "agent" => "agent_verdict" }[kind]
      end

      def errors(kind, data)
        case kind
        when "risk"    then risk_errors(data)
        when "check"   then check_errors(data)
        when "signoff" then signoff_errors(data)
        else [ "unknown kind #{kind.inspect}" ]
        end
      end

      def risk_errors(d)
        errs = []
        errs << "a risk needs a label" if d["label"].blank?
        det = d["detector"]
        if !det.is_a?(Hash)
          errs << "a risk needs a detector"
        elsif det["builtin"].present?
          errs << "unknown builtin detector #{det['builtin'].inspect}" unless Harbor::Reviews.detector?(det["builtin"])
        elsif Array(det["paths"]).empty? && Array(det["patch"]).empty? && det["words"].blank?
          errs << "a detector needs paths, patch or words"
        else
          (Array(det["paths"]) + Array(det["patch"]) + [ det["words"] ].compact).each do |re|
            Regexp.new(re.to_s)
          rescue RegexpError => e
            errs << "bad pattern #{re.inspect}: #{e.message}"
          end
        end
        errs
      end

      def check_errors(d)
        errs = []
        errs << "kind must be one of #{CHECK_KINDS.join(', ')}" unless CHECK_KINDS.include?(d["kind"])
        errs << "gate must be blocking or advisory" unless GATES.include?(d["gate"])
        errs << "stage must be one of #{STAGES.join(', ')}" unless STAGES.include?(d["stage"])
        errs << "a check must mitigate at least one risk (or \"*\")" if d["mitigates"].empty?
        run = d["run"].to_h
        case d["kind"]
        when "ci"      then errs << "a ci check needs run.job" if run["job"].blank?
        when "command" then errs << "a command check needs run.command" if run["command"].blank?
        when "agent"   then errs << "an agent check needs run.prompt" if run["prompt"].blank?
        end
        d["outputs"].each do |o|
          errs << "an output needs a name" if o["name"].blank?
          errs << "output #{o['name']}: type must be one of #{OUTPUT_TYPES.join(', ')}" unless OUTPUT_TYPES.include?(o["type"])
        end
        pass = d["pass_when"]
        if pass.is_a?(String)
          errs << "pass_when must be a condition or one of #{PASS_SHORTCUTS.join(', ')}" unless PASS_SHORTCUTS.include?(pass)
        else
          errs.concat(Condition.validate(pass).map { |e| "pass_when: #{e}" })
        end
        d["then"].each_with_index do |row, i|
          errs << "then[#{i}]: action must be one of #{ACTIONS.join(', ')}" unless ACTIONS.include?(row["action"])
          errs << "then[#{i}]: a signoff action names the signoff" if row["action"] == "signoff" && row["signoff"].blank?
          errs << "then[#{i}]: a run action names the check" if row["action"] == "run" && row["check"].blank?
          errs.concat(Condition.validate(row["when"]).map { |e| "then[#{i}]: #{e}" }) unless row["when"].is_a?(String)
        end
        errs
      end

      def signoff_errors(d)
        errs = []
        errs << "a sign-off needs who" if Array(d["who"]).empty?
        errs << "a sign-off needs a message" if d["message"].blank?
        errs
      end

      # What the form for a new rule of this kind starts with.
      def template(kind)
        case kind
        when "risk"
          { "label" => "risk: something", "description" => "What kind of change this is.",
            "detector" => { "paths" => [ "(\\A|/)app/models/" ], "patch" => [], "words" => nil } }
        when "signoff"
          { "who" => [ "a-login" ], "message" => "Approve …", "when" => { "risks" => [], "paths" => [] } }
        else
          { "description" => "What this check proves.", "mitigates" => [ "perf" ], "kind" => "command",
            "run" => { "command" => "bin/something --json" },
            "outputs" => [ { "name" => "problems", "type" => "list" } ],
            "pass_when" => { "path" => "outputs.problems", "op" => "blank" },
            "then" => [], "gate" => "blocking", "stage" => "evidence", "watch_paths" => [] }
        end
      end
    end
  end
end
