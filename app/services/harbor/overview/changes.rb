module Harbor
  module Overview
    # What changed in the configuration, newest first: Overview's feed, and
    # anything of a host's that reports changes (a weekly note, say).
    #
    # Each source reads what is versioned or timestamped and returns Changes.
    # Workflow versions, review rule versions and stage notes record who; the
    # others have a time and no author. A host adds a source of its own, or
    # replaces one of these by its name (Harbor::Overview.change_source).
    module Changes
      Change = Harbor::Overview::Change

      LIMIT = 50

      class << self
        # Harbor's sources, then the host's; a host's source named like one
        # of Harbor's stands where Harbor's stood.
        def sources
          host = Harbor::Overview.change_sources
          built_in.to_h { |name, source| [ name, host[name] || source ] }.merge(host.except(*built_in.keys))
        end

        def label_for(source) = sources[source.to_sym]&.label || source.to_s.humanize

        # Newest first across every source. since: nil is "everything recent".
        def recent(since: nil, limit: LIMIT)
          sources.values.flat_map { |source| Array(source.block.call(since:, limit:)) }
                 .sort_by { |change| -change.at.to_f }
                 .first(limit)
        end

        def this_week(limit: LIMIT) = recent(since: week_start, limit:)

        def week_start = Time.current.beginning_of_week

        private
          def routes = Harbor::Engine.routes.url_helpers

          def window(scope, since, limit, column = :updated_at)
            scope = scope.where(column => since..) if since
            scope.order(column => :desc).limit(limit)
          end

          def user_label(record, association)
            user = Harbor.config.user_class && record.public_send(association)
            user && Harbor.config.user_label.call(user)
          end

          def source(name, label, &block) = [ name, Harbor::Overview::Source.new(name:, label:, block:) ]

          def built_in
            @built_in ||= [
              source(:workflows, "Workflow") do |since:, limit:|
                versions = Harbor::WorkflowVersion.includes(:workflow)
                versions = versions.includes(:created_by_user) if Harbor.config.user_class
                window(versions, since, limit, :created_at).map do |version|
                  Change.new(at: version.created_at, source: :workflows,
                             title: "#{version.workflow.name} v#{version.number}",
                             detail: version.number == 1 ? "created" : "new version",
                             who: user_label(version, :created_by_user), url: routes.workflow_path(version.workflow))
                end
              end,
              # An agent's own fields as edited on its page (Harbor::Agent.edited_here).
              source(:agent_prompts, "Agent") do |since:, limit:|
                window(Harbor.agent_class.edited_here, since, limit).map do |agent|
                  Change.new(at: agent.updated_at, source: :agent_prompts, title: agent.display_name,
                             detail: "settings or prompt edited", url: routes.agent_path(agent))
                end
              end,
              source(:agent_documents, "Agent document") do |since:, limit:|
                window(Harbor::AgentDocument.includes(:agent), since, limit).map do |document|
                  Change.new(at: document.updated_at, source: :agent_documents, title: "#{document.agent.display_name}: #{document.path}",
                             detail: document.created_at == document.updated_at ? "added" : "edited", url: routes.agent_path(document.agent))
                end
              end,
              source(:agent_settings, "Shared context") do |since:, limit:|
                window(Harbor::AgentSetting.all, since, limit).map do |setting|
                  Change.new(at: setting.updated_at, source: :agent_settings, title: setting.key.delete_prefix("shared/"),
                             detail: "edited", url: routes.agents_path)
                end
              end,
              source(:task_routing, "Task routing") do |since:, limit:|
                window(Harbor.task_assignment_class.includes(:agent), since, limit).map do |row|
                  Change.new(at: row.updated_at, source: :task_routing, title: row.task_type,
                             detail: "→ #{row.agent&.display_name || row.agent_key}", url: routes.agents_path)
                end
              end,
              source(:model_choices, "Model") do |since:, limit:|
                window(Harbor::ModelChoice.includes(:model_alias), since, limit).map do |choice|
                  Change.new(at: choice.updated_at, source: :model_choices, title: choice.model_alias.name,
                             detail: [ "##{choice.position + 1}", Harbor.config.model_name.call(choice.model), choice.effort.presence ].compact.join(" · "),
                             url: routes.edit_model_alias_path(choice.model_alias))
                end
              end,
              source(:stage_notes, "Stage note") do |since:, limit:|
                notes = Harbor.config.user_class ? Harbor::StageNote.includes(:updated_by_user) : Harbor::StageNote.all
                window(notes, since, limit).map do |note|
                  stage = Harbor::Overview.find_stage(note.stage_key)
                  Change.new(at: note.updated_at, source: :stage_notes, title: stage&.title || note.stage_key,
                             detail: "note edited", who: note.editor_label, url: "#{routes.overview_path}##{stage&.anchor}")
                end
              end,
              source(:review_rules, "Review rules") do |since:, limit:|
                window(Harbor.review_rule_version_class.includes(:review_rule), since, limit, :created_at).map do |version|
                  rule = version.review_rule
                  Change.new(at: version.created_at, source: :review_rules,
                             title: "#{rule.kind.capitalize}: #{rule.name} v#{version.number}",
                             detail: version.number == 1 ? "created" : "edited",
                             who: version.author_label, url: routes.review_rule_path(rule))
                end
              end
            ].to_h
          end
      end
    end
  end
end
