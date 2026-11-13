require "test_helper"
require "open3"
require "tmpdir"

# A session's prompt as a slash command: the name's file, and the step that
# makes the prompt from it, run for real against a repository made here.
class HarborAgentSessionSlashCommandTest < ActiveSupport::TestCase
  SlashCommand = Harbor::AgentSession::SlashCommand

  # The shells a runner machine's `sh` is likely to be, of those here.
  SHELLS = ([ "sh" ] + %w[/bin/dash /bin/bash].select { |shell| File.executable?(shell) }).freeze
  GIT = { "GIT_CONFIG_GLOBAL" => "/dev/null", "GIT_CONFIG_SYSTEM" => "/dev/null", "GIT_AUTHOR_NAME" => "Test", "GIT_AUTHOR_EMAIL" => "test@example.com",
          "GIT_COMMITTER_NAME" => "Test", "GIT_COMMITTER_EMAIL" => "test@example.com" }.freeze

  Ran = Struct.new(:status, :output, :prompt, :stray, :dir, keyword_init: true)

  # --- the name and its file ---

  test "a name is its file in the commands folder, and a colon is a folder" do
    assert_equal ".claude/commands/tidy.md", SlashCommand.new("/tidy").path
    assert_equal ".claude/commands/tidy/shelf.md", SlashCommand.new("/tidy:shelf 12 --fast").path
    assert_equal ".claude/commands/tidy/shelf/deep.md", SlashCommand.new("/tidy:shelf:deep").path
    assert_equal ".claude/commands/re-shelve_2.0.md", SlashCommand.new("/re-shelve_2.0").path
    assert_equal ".claude/commands/.../-x.md", SlashCommand.new("/...:-x").path, "odd, but inside the folder"
    assert_equal ".claude/commands/tidy/shelf.md", SlashCommand.new("tidy:shelf").path, "the leading slash is optional"
  end

  test "what follows the name is its arguments, split on whitespace and nothing else" do
    command = SlashCommand.new("  /tidy:shelf  12\t--fast\n\"two words\" it's\u00a0here\u2003x ")
    assert_equal "tidy:shelf", command.name
    assert_equal [ "12", "--fast", "\"two", "words\"", "it's", "here", "x" ], command.arguments
    assert_equal "/tidy:shelf 12 --fast \"two words\" it's here x", command.to_s
    assert_equal "12\n--fast\n\"two\nwords\"\nit's\nhere\nx\n", command.arguments_file
    assert_equal "/tidy", SlashCommand.new("tidy").to_s
    assert_equal "", SlashCommand.new("/tidy").arguments_file
    again = SlashCommand.new(command.to_s)
    assert_equal [ command.name, command.arguments ], [ again.name, again.arguments ], "the command as shown reads back the same"
  end

  test "a name that could leave the folder, or isn't plain names, is refused" do
    [ "", "   ", "/", "//tidy", "/tidy:..", "/..:tidy", "/..", "/.", "/tidy:.", ":shelf", "/:shelf", "/tidy:", "/tidy::shelf",
      "/../../etc/passwd", "/etc/passwd", "/tidy/shelf", "/tidy\\shelf", "/tidy;id", "/tidy$(id)", "/tidy`id`", "/tidy&", "/tidy|x", "/tidy*",
      "/tidy~", "/tidy'", "/tidy\"", "/t\u00efdy", "/tidy\0", "/tidy a\0b", nil ].each do |spec|
      error = assert_raises(ArgumentError, spec.inspect) { SlashCommand.new(spec) }
      assert_match(/slash command/, error.message)
    end
    assert_equal "tidy:sh", SlashCommand.new("/tidy:sh elf").name, "a space ends the name"
  end

  test "a ref has to look like one, and can't start with a dash" do
    %w[origin/main main v1.2.3 feature/a-b_c 4f2a9c1 refs/heads/main].each do |ref|
      assert_equal ref, SlashCommand.new("/tidy", ref:).ref
    end
    assert_nil SlashCommand.new("/tidy").ref
    assert_nil SlashCommand.new("/tidy", ref: "").ref, "no ref: the worktree"
    [ "-n", "--output=x", "-", "main:other", "main other", " main", "main;id", "$(id)", "`id`", "HEAD~1", "main^", "a\nb", "main\n", "@{u}", "a&b",
      "a'b", "a\\b" ].each do |ref|
      error = assert_raises(ArgumentError, ref.inspect) { SlashCommand.new("/tidy", ref:) }
      assert_match(/command_ref/, error.message)
    end
  end

  # --- the step, on a runner ---

  # The rule the step follows, written out again: a leading `---` block goes
  # up to the next `\n---` and the whitespace after it; $ARGUMENTS is every
  # argument joined by a space; then $9 down to $1, each over the whole text
  # as the pass before left it.
  def expected(raw, arguments)
    body = raw
    if raw.start_with?("---")
      close = raw.index("\n---", 3)
      body = raw[(close + 4)..].sub(/\A#{SlashCommand::SPACE}+/o, "") if close
    end
    text = body.split("$ARGUMENTS", -1).join(arguments.join(" "))
    9.downto(1) { |number| text = text.split("$#{number}", -1).join(arguments[number - 1].to_s) }
    text
  end

  def git(dir, *words)
    output, status = Open3.capture2e(GIT, "git", "-C", dir, *words)
    assert status.success?, "git #{words.join(' ')}: #{output}"
  end

  # A repository with `files` committed. The block may change it further.
  def repository(files = {})
    Dir.mktmpdir("harbor-commands") do |root|
      dir = File.join(root, "work")
      FileUtils.mkdir_p(dir)
      git(dir, "init", "--quiet")
      git(dir, "symbolic-ref", "HEAD", "refs/heads/main")
      write(dir, files.merge("README" => "a repository"))
      git(dir, "add", "--all")
      git(dir, "commit", "--quiet", "--message", "first")
      yield dir
    end
  end

  def write(dir, files)
    files.each do |path, body|
      FileUtils.mkdir_p(File.dirname(File.join(dir, path)))
      File.binwrite(File.join(dir, path), body)
    end
  end

  # Runs the step in `dir` as the agent command would, with the run's
  # `arguments` file as Harbor serves it.
  def expand(dir, spec, ref: nil, shell: "sh")
    command = SlashCommand.new(spec, ref:)
    before = Dir.children(dir)
    Dir.mktmpdir("harbor-run") do |run_dir|
      File.binwrite(File.join(run_dir, "arguments"), command.arguments_file)
      env = GIT.merge("HARBOR_RUN_DIR" => run_dir, "PATH" => ENV.fetch("PATH"), "HOME" => run_dir)
      output, status = Open3.capture2e(env, shell, "-c", command.shell, chdir: dir, unsetenv_others: true)
      prompt = File.join(run_dir, "prompt")
      Ran.new(status: status.exitstatus, output:, prompt: (File.binread(prompt) if File.exist?(prompt)),
              stray: Dir.children(dir) - before + Dir.children(run_dir) - %w[arguments command prompt], dir: File.realpath(dir))
    end
  end

  FRONTMATTER = "---\ndescription: Tidy a shelf\nargument-hint: <shelf> [--fast]\n---\n\n".freeze

  SHELLS.each do |shell|
    test "the frontmatter is dropped and the arguments are put in (#{shell})" do
      file = "#{FRONTMATTER}Tidy shelf \#$1.\nAll of it: $ARGUMENTS\nMode: $2. Missing: [$3][$9]. Ten: $10. Again: $1$1 $ARGUMENTS\n"
      repository(".claude/commands/tidy/shelf.md" => file) do |dir|
        ran = expand(dir, "/tidy:shelf 12 --fast", shell:)

        assert_equal 0, ran.status, ran.output
        assert_equal "", ran.output
        assert_equal "Tidy shelf #12.\nAll of it: 12 --fast\nMode: --fast. Missing: [][]. Ten: 120. Again: 1212 12 --fast\n", ran.prompt
        assert_equal expected(file, %w[12 --fast]), ran.prompt
        assert_empty ran.stray
      end
    end

    test "nothing in the file or in an argument means anything to the shell, awk or sed (#{shell})" do
      file = "#{FRONTMATTER}- a line starting with a dash\n--flag $1\nampersand & \\& \\1 \\\\ \\n /slashes/ s/x/y/g\n" \
             "$(touch pwned) `touch pwned` ${HOME} $HOME $0 $ $$ %s %d \\\"quoted\\\" 'single' \"double\"\n" \
             "args: $ARGUMENTS\none: $1 two: $2 three: $3 four: $4 five: $5 six: $6 seven: $7\n\ttab [a-z]* .* ^$ | ; > out < in\n"
      spec = "/tidy:shelf a&b \\1\\\\ x/y \"q'q\" $(touch${IFS}pwned) `touch${IFS}pwned` -n"
      repository(".claude/commands/tidy/shelf.md" => file) do |dir|
        ran = expand(dir, spec, shell:)
        arguments = [ "a&b", "\\1\\\\", "x/y", "\"q'q\"", "$(touch${IFS}pwned)", "`touch${IFS}pwned`", "-n" ]

        assert_equal 0, ran.status, ran.output
        assert_equal expected(file, arguments), ran.prompt
        assert_includes ran.prompt, "- a line starting with a dash\n--flag a&b\nampersand & \\& \\1 \\\\ \\n /slashes/ s/x/y/g\n"
        assert_includes ran.prompt, "args: a&b \\1\\\\ x/y \"q'q\" $(touch${IFS}pwned) `touch${IFS}pwned` -n\n"
        assert_includes ran.prompt, "one: a&b two: \\1\\\\ three: x/y four: \"q'q\" five: $(touch${IFS}pwned) six: `touch${IFS}pwned` seven: -n\n"
        assert_empty ran.stray, "nothing was run: no pwned, no out"
        assert_equal "", ran.output
      end
    end

    test "the text comes out byte for byte, whatever its shape (#{shell})" do
      cases = {
        "no frontmatter, no newline at the end" => [ "Shelve $1", %w[12] ],
        "newlines at the end are kept" => [ "Shelve $1\n\n\n", %w[12] ],
        "an empty file" => [ "", %w[12] ],
        "only frontmatter" => [ "---\na: b\n---\n", %w[12] ],
        "frontmatter never closed is text" => [ "---\na: b\n\nShelve $1\n", %w[12] ],
        "an empty frontmatter block" => [ "---\n---\nShelve $1\n", %w[12] ],
        "windows line ends" => [ "---\r\na: b\r\n---\r\n\r\nShelve $1\r\n", %w[12] ],
        "the closing line's own tail is text" => [ "---\na: b\n--- tail\nShelve $1\n", %w[12] ],
        "a longer rule opens a block too" => [ "-----\na\n-----\nShelve $1\n", %w[12] ],
        "a later rule is text" => [ "Shelve\n\n---\n\n$1\n---\n", %w[12] ],
        "every kind of space after the block" => [ "---\na: b\n---\n \t\r\n\v\f\u00a0\u1680\u2000\u2005\u200a\u2028\u2029\u202f\u205f\u3000\ufeffShelve \u00a0$1", %w[12] ],
        "no arguments at all" => [ "Shelve [$ARGUMENTS] [$1] [$2]\n", [] ],
        "more than nine arguments" => [ "$ARGUMENTS|$1|$9|$10|$11\n", %w[a b c d e f g h i j k] ],
        "an argument that names another" => [ "$ARGUMENTS|$1|$2|$3\n", %w[$2 $3 $1 $ARGUMENTS] ],
        "names run together" => [ "$1$2$ARGUMENTS$ARGUMENTSX$ARGUMENT $123 $$1 \\$1\n", %w[x y] ],
        "text that is not ASCII" => [ "---\ntitle: caf\u00e9\n---\nR\u00e4ume $1 auf \u{1F4DA}\n", %w[zw\u00f6lf] ]
      }
      repository(cases.each_with_index.to_h { |(_, (file, _)), index| [ ".claude/commands/case-#{index}.md", file ] }) do |dir|
        cases.each_with_index do |(name, (file, arguments)), index|
          ran = expand(dir, [ "/case-#{index}", *arguments ].join(" "), shell:)
          assert_equal 0, ran.status, "#{name}: #{ran.output}"
          assert_equal expected(file, arguments).b, ran.prompt, name
          assert_empty ran.stray, name
        end
      end
      assert_equal "Shelve 12", expected("---\na: b\n--- \n\n Shelve $1", %w[12])
      assert_equal "tail\nShelve 12\n", expected("---\na: b\n--- tail\nShelve $1\n", %w[12])
      assert_equal "$3 $2 $2 $ARGUMENTS|$2|$3|$2\n", expected("$ARGUMENTS|$1|$2|$3\n", %w[$2 $3 $1 $ARGUMENTS]), "each pass reads the last one's text"
    end

    test "without a ref the file is the worktree's, committed or not (#{shell})" do
      repository(".claude/commands/tidy.md" => "committed $1\n") do |dir|
        assert_equal "committed 12\n", expand(dir, "/tidy 12", shell:).prompt

        write(dir, ".claude/commands/tidy.md" => "edited $1\n", ".claude/commands/fresh/one.md" => "never committed $1\n")
        assert_equal "edited 12\n", expand(dir, "/tidy 12", shell:).prompt
        assert_equal "never committed 12\n", expand(dir, "/fresh:one 12", shell:).prompt
      end
    end

    test "with a ref the file is that ref's, whatever is checked out (#{shell})" do
      repository(".claude/commands/tidy/shelf.md" => "#{FRONTMATTER}the ref's copy: $1\n") do |dir|
        git(dir, "update-ref", "refs/remotes/origin/main", "HEAD")
        git(dir, "checkout", "--quiet", "-b", "someone-elses-change")
        write(dir, ".claude/commands/tidy/shelf.md" => "the branch's copy, committed: $1\n")
        git(dir, "commit", "--quiet", "--all", "--message", "change the instructions")
        write(dir, ".claude/commands/tidy/shelf.md" => "the branch's copy, edited: $1\n")

        assert_equal "the branch's copy, edited: 12\n", expand(dir, "/tidy:shelf 12", shell:).prompt
        ran = expand(dir, "/tidy:shelf 12", ref: "origin/main", shell:)
        assert_equal 0, ran.status, ran.output
        assert_equal "the ref's copy: 12\n", ran.prompt, "the ref's copy wins"
        assert_equal "the branch's copy, committed: 12\n", expand(dir, "/tidy:shelf 12", ref: "someone-elses-change", shell:).prompt
        assert_equal "the branch's copy, edited: $1\n", File.read(File.join(dir, ".claude/commands/tidy/shelf.md")), "the worktree is left alone"

        FileUtils.rm_rf(File.join(dir, ".claude"))
        assert_equal "the ref's copy: 12\n", expand(dir, "/tidy:shelf 12", ref: "origin/main", shell:).prompt, "even with no copy checked out"
      end
    end

    test "a file that isn't there ends the command with one line saying where it was looked for (#{shell})" do
      repository(".claude/commands/tidy.md" => "x\n") do |dir|
        ran = expand(dir, "/tidy:shelf 12", shell:)
        assert_equal [ SlashCommand::MISSING, "ERROR: slash command /tidy:shelf not found: no .claude/commands/tidy/shelf.md in #{ran.dir}\n", nil ],
                     [ ran.status, ran.output, ran.prompt ]

        write(dir, ".claude/commands/tidy/shelf.md" => "only in the worktree\n")
        ran = expand(dir, "/tidy:shelf 12", ref: "main", shell:)
        assert_equal [ SlashCommand::MISSING, "ERROR: slash command /tidy:shelf not found: no .claude/commands/tidy/shelf.md at main in #{ran.dir}\n", nil ],
                     [ ran.status, ran.output, ran.prompt ]

        FileUtils.mkdir_p(File.join(dir, ".claude/commands/folder.md"))
        assert_equal SlashCommand::MISSING, expand(dir, "/folder", shell:).status, "a folder is not a command"
      end
    end

    test "a ref that isn't there ends the command the same way (#{shell})" do
      repository(".claude/commands/tidy.md" => "x\n") do |dir|
        ran = expand(dir, "/tidy 12", ref: "origin/main", shell:)
        assert_equal [ SlashCommand::MISSING, "ERROR: slash command /tidy not found: no ref origin/main (for .claude/commands/tidy.md) in #{ran.dir}\n", nil ],
                     [ ran.status, ran.output, ran.prompt ]
        assert_empty ran.stray
      end

      Dir.mktmpdir("harbor-plain") do |dir|
        write(dir, ".claude/commands/tidy.md" => "no repository $1\n")
        assert_equal "no repository 12\n", expand(dir, "/tidy 12", shell:).prompt, "the worktree's copy needs no git"
        ran = expand(dir, "/tidy 12", ref: "main", shell:)
        assert_equal [ SlashCommand::MISSING, "ERROR: slash command /tidy not found: no ref main (for .claude/commands/tidy.md) in #{ran.dir}\n" ],
                     [ ran.status, ran.output ]
      end
    end
  end
end
