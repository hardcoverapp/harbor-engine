require "test_helper"

class HarborAgentSessionCommandTest < ActiveSupport::TestCase
  Command = Harbor::AgentSession::Command

  setup { @bins = Harbor.config.claude_bin, Harbor.config.codex_bin }
  teardown { Harbor.config.claude_bin, Harbor.config.codex_bin = @bins }

  # A stand-in for an agent command line: it writes down what it was run
  # with (arguments, stdin, environment) and does nothing else.
  RECORDER = <<~SH.freeze
    #!/bin/sh
    for argument in "$@"; do printf '%s\\0' "$argument"; done > "$CAPTURE/argv"
    cat > "$CAPTURE/stdin"
    env > "$CAPTURE/env"
  SH

  Ran = Struct.new(:status, :output, :argv, :stdin, :env, :stray, keyword_init: true)

  # Runs a built command as the runner script would (`sh -c`), in a run
  # folder holding `files`, with stand-ins for claude and codex on the PATH.
  def run_command(command, files: {}, env: {}, bins: %w[claude codex])
    Dir.mktmpdir do |dir|
      %w[bin run capture home].each { |name| FileUtils.mkdir_p(File.join(dir, name)) }
      bins.each do |bin|
        File.write(File.join(dir, "bin", bin), RECORDER)
        File.chmod(0o755, File.join(dir, "bin", bin))
      end
      { "prompt" => "the prompt", "system" => "the system prompt", "mcp" => "{}" }.merge(files).each do |name, body|
        File.write(File.join(dir, "run", name), body)
      end
      yield dir if block_given?
      env = { "PATH" => "#{dir}/bin:/usr/bin:/bin", "HARBOR_RUN_DIR" => File.join(dir, "run"), "CAPTURE" => File.join(dir, "capture"),
              "HOME" => File.join(dir, "home") }.merge(env)
      output, status = Open3.capture2e(env, "sh", "-c", command.shell, chdir: dir, unsetenv_others: true)
      read = ->(name) { File.exist?(File.join(dir, "capture", name)) ? File.read(File.join(dir, "capture", name)) : nil }
      Ran.new(status: status.exitstatus, output:, argv: read.call("argv")&.split("\0", -1)&.tap(&:pop), stdin: read.call("stdin"),
              env: read.call("env").to_s.lines(chomp: true), stray: Dir.children(dir) - %w[bin run capture home])
    end
  end

  test "an Anthropic model runs through claude and an OpenAI one through codex" do
    anthropic = Struct.new(:model_provider).new(Struct.new(:key).new("anthropic"))
    openai = Struct.new(:model_provider).new(Struct.new(:key).new("openai"))
    assert_equal "claude", Command.cli_for(anthropic)
    assert_equal "codex", Command.cli_for(openai)
    assert_raises(ArgumentError) { Command.cli_for(Struct.new(:model_provider).new(Struct.new(:key).new("other"))) }
    assert_raises(ArgumentError) { Command.new(cli: "bash") }
  end

  test "claude is given every flag, with the prompt and system prompt read from the run's files" do
    command = Command.new(cli: "claude", model: "claude-sonnet-5-5", effort: "medium", allowed_tools: %w[Read Grep Glob],
                          disallowed_tools: %w[Bash WebFetch], add_dirs: [ "/srv/docs", "/srv/other" ], resume_session_id: "abc-123")
    ran = run_command(command, files: { "prompt" => "Fix \"it\"\n$(touch stray-prompt)\nplease", "system" => "You're `careful`." })

    assert_equal 0, ran.status, ran.output
    assert_equal [ "-p", "Fix \"it\"\n$(touch stray-prompt)\nplease",
                   "--model", "claude-sonnet-5-5", "--effort", "medium",
                   "--append-system-prompt", "You're `careful`.",
                   "--output-format", "stream-json", "--verbose",
                   "--allowedTools", "Read,Grep,Glob", "--disallowedTools", "Bash,WebFetch",
                   "--add-dir", "/srv/docs", "--add-dir", "/srv/other",
                   "--mcp-config", "#{ran.env.grep(/\AHARBOR_RUN_DIR=/).first.delete_prefix('HARBOR_RUN_DIR=')}/mcp", "--strict-mcp-config",
                   "--dangerously-skip-permissions", "--resume", "abc-123" ], ran.argv
    assert_includes ran.env, "CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0"
    assert_empty ran.stray, "nothing in the prompt was run by the shell"
  end

  test "a bare claude command still gets stream-json and an MCP config of its own, strictly" do
    words = Command.new(cli: "claude").arguments
    assert_equal [ "-p", Command::PROMPT, "--append-system-prompt", Command::SYSTEM, "--output-format", "stream-json", "--verbose",
                   "--mcp-config", Command::MCP, "--strict-mcp-config", "--dangerously-skip-permissions" ], words
    with_servers = Command.new(cli: "claude", mcp_config: { "mcpServers" => { "docs" => { "command" => "node" } } }).arguments
    assert_equal words, with_servers, "given servers or none, the run's own file is the only MCP config"
  end

  test "the permission mode maps as the CLI expects" do
    flags = ->(mode) { Command.new(cli: "claude", permission_mode: mode).arguments.drop_while { |word| word != "--strict-mcp-config" }.drop(1) }
    assert_equal [ "--dangerously-skip-permissions" ], flags.call(nil)
    assert_equal [ "--dangerously-skip-permissions" ], flags.call("")
    assert_equal [ "--dangerously-skip-permissions" ], flags.call("bypassPermissions")
    assert_equal [], flags.call("default")
    assert_equal [ "--permission-mode", "acceptEdits" ], flags.call("acceptEdits")
    assert_equal [ "--permission-mode", "plan" ], flags.call("plan")
  end

  test "an effort the CLI doesn't take is left out, and a session id is only ever what one looks like" do
    assert_not_includes Command.new(cli: "claude", effort: "ultra").arguments, "--effort"
    assert_not_includes Command.new(cli: "claude", effort: "none").arguments, "--effort"
    assert_equal "high", Command.new(cli: "claude", effort: " High ").effort

    assert_not_includes Command.new(cli: "claude", resume_session_id: "abc; rm -rf /").arguments, "--resume"
    assert_not_includes Command.new(cli: "claude", resume_session_id: "  ").arguments, "--resume"
    assert_equal [ "--resume", "7cbb9b7e-c51a.4f30_x" ], Command.new(cli: "claude", resume_session_id: " 7cbb9b7e-c51a.4f30_x ").arguments.last(2)
  end

  test "nothing a caller passes can break out of the command line" do
    hostile = [ %q(a'b"c), "$(touch stray-sub)", "`touch stray-tick`", "x; touch stray-semi; y", "two words\nand a line", "--flag", "" ]
    hostile.reject(&:empty?).each do |value|
      command = Command.new(cli: "claude", model: value, allowed_tools: [ value, "Read" ], disallowed_tools: [ value ],
                            add_dirs: [ value ], permission_mode: value)
      ran = run_command(command)
      assert_equal 0, ran.status, ran.output
      assert_empty ran.stray, "#{value.inspect} ran as shell"
      assert_equal value, ran.argv[ran.argv.index("--model") + 1]
      assert_equal "#{value},Read", ran.argv[ran.argv.index("--allowedTools") + 1]
      assert_equal value, ran.argv[ran.argv.index("--disallowedTools") + 1]
      assert_equal value, ran.argv[ran.argv.index("--add-dir") + 1]
      assert_equal value, ran.argv[ran.argv.index("--permission-mode") + 1]
    end

    codex = Command.new(cli: "codex", model: "$(touch stray-model)", add_dirs: [ "it's; touch stray-dir" ],
                        mcp_config: { "mcpServers" => { "docs" => { "command" => "$(touch stray-mcp)", "args" => [ "a'b" ],
                                                                    "env" => { "K" => "`touch stray-env`" } } } })
    ran = run_command(codex)
    assert_equal 0, ran.status, ran.output
    assert_empty ran.stray
    assert_equal "$(touch stray-model)", ran.argv[ran.argv.index("--model") + 1]
    assert_includes ran.argv, "it's; touch stray-dir"
    assert_includes ran.argv, 'mcp_servers.docs.command="$(touch stray-mcp)"'
    assert_includes ran.argv, %q(mcp_servers.docs.args=["a'b"])
    assert_includes ran.argv, 'mcp_servers.docs.env={"K" = "`touch stray-env`"}'
  end

  test "a machine without the command says so in one line and exits 127" do
    ran = run_command(Command.new(cli: "claude"), bins: [])
    assert_equal 127, ran.status
    assert_equal "harbor: the claude command (claude) isn't installed on this machine, or isn't on its PATH.\n", ran.output
    assert_nil ran.argv

    ran = run_command(Command.new(cli: "codex"), bins: %w[claude])
    assert_equal 127, ran.status
    assert_match "the codex command (codex) isn't installed", ran.output
  end

  test "the binary is the one the host configured" do
    Harbor.config.claude_bin = "claude-next"
    Harbor.config.codex_bin = "/opt/tools/my codex"
    assert_match(/exec claude-next -p /, Command.new(cli: "claude").shell)
    assert_match(%r{command -v /opt/tools/my\\ codex }, Command.new(cli: "codex").shell)
    assert_match(%r{\| /opt/tools/my\\ codex exec --json }, Command.new(cli: "codex").shell)
    assert_equal "claude -p <prompt…>", Command.new(cli: "claude", permission_mode: "default").display, "a person is shown the plain name"

    ran = run_command(Command.new(cli: "claude"), bins: %w[claude-next])
    assert_equal 0, ran.status, ran.output
  end

  # --- codex: the policy cases of the reference implementation ---

  test "codex keeps read-only policies, explicit MCP servers and the model's effort" do
    words = Command.new(cli: "codex", model: "gpt-5.5", effort: "high", disallowed_tools: %w[Edit Write Bash Agent],
                        mcp_config: { mcpServers: { docs: { command: "node", args: [ "docs.js" ] } } }).arguments
    assert_equal "read-only", words[words.index("--sandbox") + 1]
    assert_includes words, 'model_reasoning_effort="high"'
    assert_includes words, "features.shell_tool=false"
    assert_includes words, 'mcp_servers.docs.command="node"'
    assert_includes words, 'mcp_servers.docs.args=["docs.js"]'
    assert_equal [ "exec", "--json", "--skip-git-repo-check" ], words.first(3)
    assert_includes words, 'approval_policy="never"'
    assert_includes words, "features.multi_agent=false"
    assert_equal [ "--model", "gpt-5.5" ], words[words.index("--model"), 2]
    assert_equal "-", words.last, "the prompt arrives on stdin"
  end

  test "a read-only allow list runs codex in its read-only sandbox" do
    words = Command.new(cli: "codex", allowed_tools: %w[Read Grep Glob], permission_mode: "bypassPermissions").arguments
    assert_equal "read-only", words[words.index("--sandbox") + 1]
  end

  test "tool rules codex can't enforce fail closed" do
    error = assert_raises(Command::PolicyError) { Command.new(cli: "codex", allowed_tools: %w[Read WebFetch]).shell }
    assert_match(/allowedTools/, error.message)
    error = assert_raises(Command::PolicyError) { Command.new(cli: "codex", disallowed_tools: %w[WebSearch]).shell }
    assert_match(/disallowedTools/, error.message)
    assert_raises(Command::PolicyError) { Command.new(cli: "codex", mcp_config: { "mcpServers" => { "bad name" => { "command" => "x" } } }).shell }
  end

  test "the codex sandbox follows the permission mode when no rule narrows it" do
    sandbox = ->(**options) { Command.new(cli: "codex", **options).arguments.then { |words| words[words.index("--sandbox") + 1] } }
    assert_equal "danger-full-access", sandbox.call
    assert_equal "danger-full-access", sandbox.call(permission_mode: "bypassPermissions")
    assert_equal "read-only", sandbox.call(permission_mode: "default")
    assert_equal "workspace-write", sandbox.call(permission_mode: "acceptEdits")
    assert_equal "read-only", sandbox.call(permission_mode: "acceptEdits", disallowed_tools: %w[Write])
    assert_equal "danger-full-access", sandbox.call(disallowed_tools: %w[Bash Agent]), "denying the shell alone doesn't make it read-only"
    assert_not_includes Command.new(cli: "codex", disallowed_tools: %w[Agent]).arguments, "features.shell_tool=false"
  end

  test "codex gets the system text and the prompt on stdin, in a home of its own" do
    command = Command.new(cli: "codex", model: "gpt-5.5", resume_session_id: "abc-123")
    assert_nil command.resume_session_id, "codex is not asked to continue a session"

    ran = run_command(command, files: { "system" => "Be brief.", "prompt" => "Fix it." })
    assert_equal 0, ran.status, ran.output
    assert_equal "Be brief.\n\n---\n\nFix it.", ran.stdin
    run_dir = ran.env.grep(/\AHARBOR_RUN_DIR=/).first.delete_prefix("HARBOR_RUN_DIR=")
    assert_includes ran.env, "CODEX_HOME=#{run_dir}/codex"
    assert_equal [ "exec", "--json" ], ran.argv.first(2)
  end

  test "codex's own home holds the saved login and nothing else, and not even that when a key was passed" do
    copied = lambda do |env|
      Dir.mktmpdir do |seen|
        run_command(Command.new(cli: "codex"), env:) do |dir|
          FileUtils.mkdir_p(File.join(dir, "home/.codex"))
          File.write(File.join(dir, "home/.codex/auth.json"), '{"login":"saved"}')
          File.write(File.join(dir, "home/.codex/config.toml"), "[mcp_servers.mail]\n")
          File.write(File.join(dir, "bin/codex"), "#{RECORDER}cp -R \"$CODEX_HOME/.\" \"#{seen}\"\n")
        end
        Dir.children(seen).sort
      end
    end
    assert_equal [ "auth.json" ], copied.call({}), "the machine's codex config (its MCP servers) is not inherited"
    assert_equal [], copied.call({ "CODEX_API_KEY" => "key-from-the-host" })
  end

  test "with no system text codex gets the prompt alone" do
    ran = run_command(Command.new(cli: "codex"), files: { "system" => "", "prompt" => "Just this." })
    assert_equal "Just this.", ran.stdin
  end

  test "what a person is shown has no file plumbing and no prompt" do
    command = Command.new(cli: "claude", model: "claude-sonnet-5-5", effort: "medium", allowed_tools: %w[Read Grep Glob],
                          disallowed_tools: %w[Bash], permission_mode: "plan", resume_session_id: "abc", add_dirs: [ "/srv/docs" ])
    assert_equal "claude -p <prompt…> --model claude-sonnet-5-5 --effort medium --allowedTools Read,Grep,Glob " \
                 "--disallowedTools Bash --permission-mode plan --resume abc", command.display
    assert_equal "codex exec <prompt…> --sandbox read-only --model gpt-5.5 --effort high",
                 Command.new(cli: "codex", model: "gpt-5.5", effort: "high", allowed_tools: %w[Read]).display
    assert_no_match(/HARBOR_RUN_DIR|mcp/, command.display)
  end

  test "a command can be built again from what was kept, with or without the session it continued" do
    command = Command.new(cli: "claude", model: "claude-sonnet-5-5", effort: "high", allowed_tools: %w[Read], disallowed_tools: %w[Bash],
                          add_dirs: [ "/srv/docs" ], permission_mode: "plan", resume_session_id: "abc")
    again = Command.from(JSON.parse(command.to_h.to_json))
    assert_equal command.shell, again.shell
    fresh = again.without_resume
    assert_nil fresh.resume_session_id
    assert_equal command.arguments - [ "--resume", "abc" ], fresh.arguments
  end
end

class HarborAgentSessionEnvironmentTest < ActiveSupport::TestCase
  Environment = Harbor::AgentSession::Environment

  setup { @hook = Harbor.config.agent_session_env }
  teardown { Harbor.config.agent_session_env = @hook }

  def run_record = Harbor::Run.new(id: 7)

  # What a shell that sources the file ends up with, for the names asked.
  def sourced(file, names, env: {})
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "env"), file)
      script = %(. "#{dir}/env"; ) + names.map { |name| %(printf '%s\\0' "${#{name}-<unset>}") }.join("; ")
      out, status = Open3.capture2(env, "sh", "-c", script, unsetenv_others: true, chdir: dir)
      assert status.success?
      assert_empty Dir.children(dir) - [ "env" ], "sourcing the file ran something"
      names.zip(out.split("\0", -1)).to_h
    end
  end

  test "with no hook the command gets nothing of Harbor's" do
    Harbor.config.agent_session_env = nil
    assert_equal({}, Environment.for(run_record, "anthropic"))
    assert_equal "", Environment.file(run_record, "anthropic")
  end

  test "the hook is given the run and the provider, and its values reach a shell exactly" do
    asked = []
    values = { "GH_TOKEN" => "plain", "QUOTED" => %q(it's "quoted"), "SHELLY" => "$(touch stray) `touch stray2` $HOME",
               "LINES" => "one\ntwo", :GIT_AUTHOR_NAME => "Sam Example", "COUNT" => 3, "SKIPPED" => nil }
    Harbor.config.agent_session_env = ->(run, provider) { asked << [ run.id, provider ]; values }

    file = Environment.file(run_record, "openai")
    assert_equal [ [ 7, "openai" ] ], asked
    got = sourced(file, %w[GH_TOKEN QUOTED SHELLY LINES GIT_AUTHOR_NAME COUNT SKIPPED])
    assert_equal({ "GH_TOKEN" => "plain", "QUOTED" => %q(it's "quoted"), "SHELLY" => "$(touch stray) `touch stray2` $HOME",
                   "LINES" => "one\ntwo", "GIT_AUTHOR_NAME" => "Sam Example", "COUNT" => "3", "SKIPPED" => "<unset>" }, got)
    assert_match(/^export GH_TOKEN='plain'$/, file)
  end

  test "claude gets one credential: whichever the host passes, the other is unset for the command" do
    machine = { "ANTHROPIC_API_KEY" => "machine-key", "CLAUDE_CODE_OAUTH_TOKEN" => "machine-oauth" }
    names = %w[ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN]

    Harbor.config.agent_session_env = ->(*) { { "CLAUDE_CODE_OAUTH_TOKEN" => "host-oauth" } }
    assert_equal({ "ANTHROPIC_API_KEY" => "<unset>", "CLAUDE_CODE_OAUTH_TOKEN" => "host-oauth" },
                 sourced(Environment.file(run_record, "anthropic"), names, env: machine))

    Harbor.config.agent_session_env = ->(*) { { "ANTHROPIC_API_KEY" => "host-key" } }
    assert_equal({ "ANTHROPIC_API_KEY" => "host-key", "CLAUDE_CODE_OAUTH_TOKEN" => "<unset>" },
                 sourced(Environment.file(run_record, "anthropic"), names, env: machine))

    Harbor.config.agent_session_env = ->(*) { { "GH_TOKEN" => "x" } }
    assert_equal machine, sourced(Environment.file(run_record, "anthropic"), names, env: machine),
                 "with neither, the machine's own login is left as it is"

    Harbor.config.agent_session_env = ->(*) { { "ANTHROPIC_API_KEY" => "host-key", "CLAUDE_CODE_OAUTH_TOKEN" => "host-oauth" } }
    assert_equal({ "ANTHROPIC_API_KEY" => "<unset>", "CLAUDE_CODE_OAUTH_TOKEN" => "host-oauth" },
                 sourced(Environment.file(run_record, "anthropic"), names, env: machine), "given both, the OAuth token is the one used")
  end

  test "an OAuth token put in the API key is passed as the OAuth token it is" do
    Harbor.config.agent_session_env = ->(*) { { "ANTHROPIC_API_KEY" => "sk-ant-oat01-setup" } }
    assert_equal({ "ANTHROPIC_API_KEY" => "<unset>", "CLAUDE_CODE_OAUTH_TOKEN" => "sk-ant-oat01-setup" },
                 sourced(Environment.file(run_record, "anthropic"), %w[ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN],
                         env: { "ANTHROPIC_API_KEY" => "machine-key" }))
  end

  test "a name that isn't an environment variable's, or is the runner's own, is refused without showing the value" do
    [ "BAD NAME", "1ST", "A=B", "A;touch x", "", "HARBOR_RUN_DIR", "HARBOR_RUNNER_TOKEN" ].each do |name|
      Harbor.config.agent_session_env = ->(*) { { name => "the-secret-value" } }
      error = assert_raises(Environment::Invalid, name) { Environment.file(run_record, "anthropic") }
      assert_no_match(/the-secret-value/, error.message)
    end
    Harbor.config.agent_session_env = ->(*) { "not a hash" }
    assert_raises(Environment::Invalid) { Environment.file(run_record, "anthropic") }
  end
end
