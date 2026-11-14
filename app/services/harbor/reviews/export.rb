module Harbor
  module Reviews
    # Every saved rule version is also handed to the host to keep outside the
    # database (`config.export`): reviews/<kind>s/<repo>/<key>.json, the
    # latest version, where <repo> is the rule's repository with "_" for "/"
    # ("_all" for every repository). With no export hook nothing is written.
    module Export
      DIR = "reviews".freeze

      module_function

      def path_for(rule)
        repo = rule.repo == "*" ? "_all" : rule.repo.tr("/", "_")
        File.join(DIR, "#{rule.kind}s", repo, "#{rule.key}.json")
      end

      def body_for(rule, version = rule.current_version)
        JSON.pretty_generate(
          "kind" => rule.kind, "key" => rule.key, "repo" => rule.repo, "name" => rule.name,
          "mode" => rule.mode, "version" => version.number, "definition" => version.definition
        ) + "\n"
      end

      def write(rule)
        hook = Harbor.config.export or return
        version = rule.current_version or return
        hook.call(path_for(rule), body_for(rule, version))
      rescue => e
        Rails.logger.error("[harbor] export of review rule #{rule.kind}/#{rule.key} failed: #{e.class}: #{e.message}")
      end
    end
  end
end
