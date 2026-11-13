require "shellwords"

module Harbor
  module AgentSession
    # The shell command that runs one agent CLI for a session: `claude -p` for
    # an Anthropic model, `codex exec` for an OpenAI one.
    #
    # The command runs inside the runner script (Harbor::Runner), which has
    # already fetched the run's files into $HARBOR_RUN_DIR: the prompt, the
    # system prompt and the MCP config are read from there, so none of them,
    # and no secret, is part of this text. Everything that is part of it is
    # shell-escaped. With a slash command the prompt is not fetched: a first
    # step of the command writes it there, from the command's file in the
    # repository (SlashCommand).
    #
    #   command = Command.new(cli: "claude", model: "claude-sonnet-5-5", effort: "medium")
    #   command.shell     # what the terminal runs
    #   command.display   # what a person is shown (runs.command)
    class Command
      # The tool rules can't be enforced by this CLI. Nothing is started.
      class PolicyError < StandardError; end

      CLIS = %w[claude codex].freeze
      PROVIDER_CLIS = { "anthropic" => "claude", "openai" => "codex" }.freeze
      # The reasoning depths the CLIs take; any other value is left out.
      EFFORTS = %w[low medium high xhigh max].freeze
      # A session id is put on a command line, so only what one looks like.
      SESSION_ID = /\A[A-Za-z0-9._-]+\z/
      MCP_SERVER_NAME = /\A[a-zA-Z0-9_-]+\z/
      MCP_FIELDS = %w[command args url env].freeze

      # Shell text put into the command as it is: a reference to a file in
      # the run's folder, never a value from a caller.
      Raw = Struct.new(:text)
      PROMPT = Raw.new('"$(cat "$HARBOR_RUN_DIR/prompt")"').freeze
      SYSTEM = Raw.new('"$(cat "$HARBOR_RUN_DIR/system")"').freeze
      MCP = Raw.new('"$HARBOR_RUN_DIR/mcp"').freeze

      # The CLI that runs a model choice, from its provider.
      def self.cli_for(choice)
        provider = choice.model_provider&.key
        PROVIDER_CLIS.fetch(provider.to_s) { raise ArgumentError, "No agent command runs models from #{provider.inspect}." }
      end

      attr_reader :cli, :model, :effort, :permission_mode, :allowed_tools, :disallowed_tools, :add_dirs,
                  :mcp_config, :resume_session_id, :slash_command

      def initialize(cli:, model: nil, effort: nil, permission_mode: nil, allowed_tools: nil, disallowed_tools: nil,
                     add_dirs: nil, mcp_config: nil, resume_session_id: nil, slash_command: nil, command_ref: nil, bin: nil)
        raise ArgumentError, "unknown agent command #{cli.inspect}" unless CLIS.include?(cli.to_s)

        @cli = cli.to_s
        @model = model.presence
        effort = effort.to_s.strip.downcase
        @effort = effort if EFFORTS.include?(effort)
        @permission_mode = permission_mode.presence || "bypassPermissions"
        @allowed_tools = Array(allowed_tools).map(&:to_s).compact_blank
        @disallowed_tools = Array(disallowed_tools).map(&:to_s).compact_blank
        @add_dirs = Array(add_dirs).map(&:to_s).compact_blank
        @mcp_config = mcp_config.is_a?(Hash) ? mcp_config.deep_stringify_keys : nil
        resume = resume_session_id.to_s.strip
        # codex exec has no flag that continues a session by id here.
        @resume_session_id = resume if @cli == "claude" && resume.match?(SESSION_ID)
        # The prompt is a file in the repository (SlashCommand), not text.
        @slash_command = slash_command.is_a?(SlashCommand) ? slash_command : SlashCommand.new(slash_command, ref: command_ref) if slash_command.present?
        @bin = bin.presence || Harbor.config.public_send("#{@cli}_bin")
      end

      # What is needed to build this command again (the MCP config apart,
      # which is kept with the run's other files).
      def to_h
        { "cli" => cli, "model" => model, "effort" => effort, "permission_mode" => permission_mode,
          "allowed_tools" => allowed_tools, "disallowed_tools" => disallowed_tools, "add_dirs" => add_dirs,
          "resume_session_id" => resume_session_id }.merge(slash_command ? { "slash_command" => slash_command.to_s, "command_ref" => slash_command.ref } : {})
      end

      # The run's files the runner fetches for this command. A slash command
      # makes the prompt on the runner, from its file and the arguments.
      def bundle = [ slash_command ? "arguments" : "prompt", "system", "mcp", "env" ]

      def self.from(hash, mcp_config: nil) = new(**hash.to_h.symbolize_keys, mcp_config:)

      # The same command starting a new session instead of continuing one.
      def without_resume = self.class.from(to_h.merge("resume_session_id" => nil), mcp_config:)

      # The command line the runner script runs with `sh -c`.
      def shell = cli == "codex" ? codex_shell : claude_shell

      # The command as a person is shown it: no file plumbing, and no prompt
      # but a slash command.
      def display
        prompt = slash_command&.to_s || "<prompt…>"
        if cli == "codex"
          words = [ "codex", "exec", prompt, "--sandbox", codex_sandbox ]
          words += [ "--model", model ] if model
          words += [ "--effort", effort ] if effort
        else
          words = [ "claude", "-p", prompt ]
          words += [ "--model", model ] if model
          words += [ "--effort", effort ] if effort
          words += [ "--allowedTools", allowed_tools.join(",") ] if allowed_tools.any?
          words += [ "--disallowedTools", disallowed_tools.join(",") ] if disallowed_tools.any?
          words += permission_flags
          words += [ "--resume", resume_session_id ] if resume_session_id
        end
        words.join(" ")
      end

      # The arguments after the binary, as shell words (escaped, or Raw).
      def arguments = cli == "codex" ? codex_arguments : claude_arguments

      private

      def claude_shell
        [ preflight, *slash_command&.shell,
          # In print mode the CLI gives background subagents ten minutes after
          # the main turn ends, then ends them and exits 0: a review fanned out
          # over many subagents is cut off with nothing posted and still looks
          # like a success. The session's own timeout is the real limit, so
          # this one is switched off.
          "export CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0",
          "exec #{line(claude_arguments)}" ].join("; ")
      end

      # The built-in tools an allow list names: "Bash(git *)" is Bash, and a
      # tool of an MCP server ("mcp__…") is not built in, so --tools has
      # nothing to say about it. Empty when the list names only MCP tools,
      # which leaves the session no built-in tool at all.
      def built_in_tools
        allowed_tools.map { |tool| tool.sub(/\(.*\z/m, "").strip }.reject { |tool| tool.empty? || tool.start_with?("mcp__") }.uniq
      end

      def claude_arguments
        words = [ "-p", PROMPT ]
        words += [ "--model", model ] if model
        words += [ "--effort", effort ] if effort
        words += [ "--append-system-prompt", SYSTEM ]
        # --verbose is required with stream-json in print mode. Partial
        # messages are left off: token deltas would flood the log.
        words += [ "--output-format", "stream-json", "--verbose" ]
        # --allowedTools says what is approved without asking; with
        # permissions skipped everything is approved anyway, so by itself it
        # restricts nothing. --tools is what takes the other built-in tools
        # away, making the list mean "these and no others". A denied tool
        # stays denied whatever the mode.
        # Whether a list is enforced is a setting, off unless a site turns it
        # on: where everyone using the system is trusted, an agent has every
        # tool and its list only says what needs no approval.
        if allowed_tools.any?
          words += [ "--tools", built_in_tools.join(",") ] if Harbor::Setting.get(:agent_allow_lists_enforced)
          words += [ "--allowedTools", allowed_tools.join(",") ]
        end
        words += [ "--disallowedTools", disallowed_tools.join(",") ] if disallowed_tools.any?
        add_dirs.each { |dir| words += [ "--add-dir", dir ] }
        # Always its own MCP config and nothing else: without --strict-mcp-config
        # a session inherits every MCP server of whoever owns the machine.
        words += [ "--mcp-config", MCP, "--strict-mcp-config" ]
        words += permission_flags
        words += [ "--resume", resume_session_id ] if resume_session_id
        words
      end

      # Print mode can't answer a permission prompt, so by default they are
      # skipped; "default" keeps the CLI's own sandbox, and any other mode is
      # passed through.
      def permission_flags
        case permission_mode
        when "bypassPermissions" then [ "--dangerously-skip-permissions" ]
        when "default" then []
        else [ "--permission-mode", permission_mode ]
        end
      end

      def codex_shell
        [ preflight, *slash_command&.shell,
          # A home of its own, so the session sees no MCP server or setting
          # from the machine owner's codex config. Only the saved login is
          # copied in, and only when no API key was passed.
          'harbor_codex_login="${CODEX_HOME:-$HOME/.codex}/auth.json"',
          'export CODEX_HOME="$HARBOR_RUN_DIR/codex"',
          'mkdir -p "$CODEX_HOME"',
          'if [ -z "${CODEX_API_KEY:-}" ] && [ -f "$harbor_codex_login" ]; then cp "$harbor_codex_login" "$CODEX_HOME/auth.json"; fi',
          # codex has no system prompt flag: the system text goes first in
          # the prompt, and the whole of it arrives on stdin.
          '{ if [ -s "$HARBOR_RUN_DIR/system" ]; then cat "$HARBOR_RUN_DIR/system"; printf \'\n\n---\n\n\'; fi; ' \
          "cat \"$HARBOR_RUN_DIR/prompt\"; } | #{line(codex_arguments)}" ].join("; ")
      end

      def codex_arguments
        check_codex_policy!
        words = [ "exec", "--json", "--skip-git-repo-check", "--sandbox", codex_sandbox, "-c", 'approval_policy="never"' ]
        words += [ "--model", model ] if model
        words += [ "-c", "model_reasoning_effort=#{effort.to_json}" ] if effort
        words += [ "-c", "features.shell_tool=false" ] if disallowed_tools.include?("Bash")
        words += [ "-c", "features.multi_agent=false" ]
        add_dirs.each { |dir| words += [ "--add-dir", dir ] }
        words += codex_mcp_arguments
        words << "-"
      end

      def check_codex_policy!
        unless (allowed_tools - ToolPolicy::READ_ONLY_TOOLS).empty?
          raise PolicyError, "Codex supports only read-only allowedTools (#{ToolPolicy::READ_ONLY_TOOLS.join(', ')}). " \
                             "Use an Anthropic model for this agent."
        end
        return if (disallowed_tools - ToolPolicy::CODEX_DISALLOWED_TOOLS).empty?
        raise PolicyError, "Codex cannot enforce this disallowedTools policy."
      end

      def codex_sandbox
        read_only = allowed_tools.any? || disallowed_tools.intersect?(ToolPolicy::WRITING_TOOLS)
        return "read-only" if read_only || permission_mode == "default"
        permission_mode == "acceptEdits" ? "workspace-write" : "danger-full-access"
      end

      # codex reads MCP servers from its config; each field of each server
      # the run was given becomes a config override.
      def codex_mcp_arguments
        servers = mcp_config&.dig("mcpServers")
        return [] unless servers.is_a?(Hash)

        servers.flat_map do |name, spec|
          raise PolicyError, "Invalid MCP server name" unless name.to_s.match?(MCP_SERVER_NAME)
          MCP_FIELDS.flat_map do |field|
            value = spec.is_a?(Hash) ? spec[field] : nil
            next [] if value.nil?
            [ "-c", "mcp_servers.#{name}.#{field}=#{field == 'env' ? toml_table(value) : value.to_json}" ]
          end
        end
      end

      def toml_table(pairs) = "{#{pairs.to_h.map { |key, value| "#{key.to_s.to_json} = #{value.to_s.to_json}" }.join(', ')}}"

      # One clear line instead of the shell's "not found" when the machine
      # has no such command.
      def preflight
        bin = Shellwords.escape(@bin)
        message = Shellwords.escape("harbor: the #{cli} command (#{@bin}) isn't installed on this machine, or isn't on its PATH.")
        "command -v #{bin} >/dev/null 2>&1 || { echo #{message}; exit 127; }"
      end

      def line(words) = [ Shellwords.escape(@bin), *words.map { |word| word.is_a?(Raw) ? word.text : Shellwords.escape(word) } ].join(" ")
    end
  end
end
