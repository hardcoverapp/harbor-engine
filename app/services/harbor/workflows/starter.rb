module Harbor
  module Workflows
    # Starts a run of a workflow: Harbor::Workflows.start!(workflow, …).
    #
    #   trigger:   what started it, as the steps read it (`trigger.*`)
    #   kind:      the trigger's kind: "manual", "workflow" (a call step), or
    #              whatever the host calls its own
    #   input:     what the steps read as `input.*`
    #   user:      the host's user who started it, if someone did
    #   subject:   what the run is about: { repo:, pr_number:, issue_number: },
    #              any of them. Left out, `config.workflow_subject` is asked
    #              (with the trigger and the input); with no hook the run is
    #              about nothing.
    #   webhook_event:, dedupe_key:   the delivery that started it, and a key
    #              that lets one delivery start a workflow only once
    #   parent:, parent_step_key:     the run and call step that started it
    #   force_dry_run:   a dry run even when the workflow is live
    #
    # A run is live only when the workflow is live and the master switch is
    # on; otherwise it is a dry run. A child run takes its parent's mode.
    #
    # One active run per workflow per subject: a second firing while one is
    # going is dropped (nil is returned), because the first is already
    # handling it. nil too for a workflow with no saved version, and for a
    # dedupe key already used.
    class Starter
      def self.call(workflow, **options) = new(workflow, **options).call

      def initialize(workflow, trigger:, kind:, input: {}, user: nil, subject: nil, webhook_event: nil, dedupe_key: nil,
                     parent: nil, parent_step_key: nil, force_dry_run: false)
        @workflow = workflow
        @trigger = trigger.to_h
        @kind = kind
        @input = input.to_h
        @user = user
        @subject = subject
        @webhook_event = webhook_event
        @dedupe_key = dedupe_key
        @parent = parent
        @parent_step_key = parent_step_key
        @force_dry_run = force_dry_run
      end

      def call
        version = @workflow.current_version or return nil
        about = subject
        repo, pr, issue = about.values_at(:repo, :pr_number, :issue_number)
        return nil if @parent.nil? && busy?(repo, pr, issue)

        run = Harbor.workflow_run_class.create!(
          workflow: @workflow, workflow_version: version, status: "queued",
          # Live only when the workflow is live AND the master switch is on.
          mode: @parent&.mode || (@workflow.live? && Harbor::Workflows.enabled? && !@force_dry_run ? "live" : "dry_run"),
          trigger_kind: @kind, webhook_event: @webhook_event, triggered_by_user_id: @user.try(:id),
          parent_workflow_run: @parent, parent_step_key: @parent_step_key,
          github_repo: repo, pr_number: pr, issue_number: issue,
          dedupe_key: @dedupe_key,
          context: { "trigger" => @trigger, "input" => @input, "settings" => version.parsed.settings }
        )
        run.update!(context: run.context.merge("run" => { "id" => run.id, "url" => Harbor::Workflows::Starter.run_url(run),
                                                          "pr" => pr, "issue" => issue }.compact))
        Harbor::Workflows.advance_later(run.id)
        run
      rescue ActiveRecord::RecordNotUnique
        nil # the same delivery already started this workflow
      end

      # The address of a run's page, as steps and messages give it out: the
      # host's (`config.workflow_run_url`), else the page's path after the
      # site's address, when the Runner address setting names one.
      def self.run_url(run)
        hook = Harbor.config.workflow_run_url
        return hook.call(run) if hook
        "#{Harbor::Setting.get(:runner_url).to_s.chomp('/')}#{Harbor.path}/workflow_runs/#{run.id}"
      end

      private

      def subject
        about = @subject || Harbor.config.workflow_subject&.call(@trigger, @input) || {}
        about.to_h.symbolize_keys
      end

      def busy?(repo, pr, issue)
        return false unless pr || issue
        busy = @workflow.workflow_runs.active.where(github_repo: repo)
        busy = pr ? busy.where(pr_number: pr) : busy.where(issue_number: issue)
        return false unless busy.exists?
        Rails.logger.info("[harbor] workflow #{@workflow.key} already running for #{pr ? "PR ##{pr}" : "issue ##{issue}"}; not starting another")
        true
      end
    end
  end
end
