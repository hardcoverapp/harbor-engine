module Harbor
  module Automations
    # An agent automation's run as an agent session (Harbor::AgentSession):
    # the automation's agent, with its instructions or its slash command, in
    # a worktree on a runtime of the agent's workspace, for as long as the
    # automation allows.
    module Session
      # Why a run can't be started as a session.
      class Refused < StandardError; end

      module_function

      # Starts `run`. `prompt` and `slash_command` are the automation's, with
      # their placeholders filled in; one of them is given. Returns the run:
      # running, or still waiting (queued, waiting_for_model) when the agent
      # or every runtime is full or no model is available, in which case the
      # caller asks again later.
      #
      #   workspace     place on this workspace instead of the agent's own
      #   command_ref   the git ref a slash command's file is read from; the
      #                 site's setting unless given
      def start!(run:, automation:, agent:, prompt: nil, slash_command: nil, workspace: nil, command_ref: :setting)
        raise Refused, "This automation has neither instructions nor a slash command." if prompt.blank? && slash_command.blank?

        command_ref = Harbor::Setting.get(:automation_command_ref).presence if command_ref == :setting
        what = slash_command.present? ? { slash_command:, command_ref: } : { prompt: }
        Harbor::AgentSession.run!(agent:, run:, workspace:, timeout: (automation.timeout_ms / 1000.0).seconds, **what)
      rescue ArgumentError => e
        # A slash command Harbor won't take (a name that isn't a plain one).
        raise Refused, e.message
      end
    end
  end
end
