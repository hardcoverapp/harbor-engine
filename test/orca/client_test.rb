require "test_helper"

class HarborOrcaClientTest < ActiveSupport::TestCase
  # Stands in for the orca command: records each argv and answers from a queue.
  class FakeOrca
    attr_reader :calls

    def initialize(*replies)
      @replies = replies
      @calls = []
    end

    def call(argv, timeout:)
      @calls << { argv: argv, timeout: timeout }
      reply = @replies.shift or raise "no reply queued for #{argv.inspect}"
      reply.is_a?(Array) ? reply : [ JSON.generate(reply), "", reply["ok"] ? 0 : 1 ]
    end

    def argv = calls.last[:argv]
  end

  def ok(result) = { "ok" => true, "result" => result }
  def refused(code, data = nil) = { "ok" => false, "error" => { "code" => code, "message" => code, "data" => data }.compact }

  def client(orca, **options) = Harbor::Orca::Client.new(bin: "orca", runner: orca, **options)

  WORKTREE = { "id" => "repo-1::/work/spaces/run-7", "path" => "/work/spaces/run-7", "branch" => "refs/heads/run-7" }.freeze

  test "status reports the version and readiness" do
    orca = FakeOrca.new(ok("runtime" => { "appVersion" => "1.4.250", "state" => "ready", "reachable" => true }))
    assert_equal({ version: "1.4.250", ready: true }, client(orca).status)
    assert_equal %w[orca status --json], orca.argv
  end

  test "a server that isn't reachable isn't ready" do
    orca = FakeOrca.new(ok("runtime" => { "appVersion" => "1.4.250", "state" => "ready", "reachable" => false }))
    assert_equal false, client(orca).status[:ready]
  end

  test "every command names the paired server when there is one" do
    orca = FakeOrca.new(ok("runtime" => {}))
    client(orca, environment: "build-box").status
    assert_equal %w[orca status --json --environment build-box], orca.argv
  end

  test "creates a worktree from a base and returns where it is" do
    orca = FakeOrca.new(ok("worktree" => WORKTREE))
    worktree = client(orca).create_worktree(repo: "name:app", name: "run-7", base: "main")
    assert_equal %w[orca worktree create --repo name:app --name run-7 --setup skip --base-branch main --json], orca.argv
    assert_equal "/work/spaces/run-7", worktree.path
    assert_equal "repo-1::/work/spaces/run-7", worktree.id
    assert_equal "refs/heads/run-7", worktree.branch
  end

  test "a worktree's path falls back to the one in its id" do
    orca = FakeOrca.new(ok("worktree" => { "id" => "repo-1::/work/spaces/run-8" }))
    assert_equal "/work/spaces/run-8", client(orca).create_worktree(repo: "name:app", name: "run-8").path
  end

  test "looks a worktree up by path, id or selector" do
    orca = FakeOrca.new(ok("worktree" => WORKTREE), ok("worktree" => WORKTREE), ok("worktree" => WORKTREE))
    c = client(orca)
    c.worktree("/work/spaces/run-7")
    assert_equal "path:/work/spaces/run-7", orca.argv[4]
    c.worktree("repo-1::/work/spaces/run-7")
    assert_equal "id:repo-1::/work/spaces/run-7", orca.argv[4]
    c.worktree("branch:run-7")
    assert_equal "branch:run-7", orca.argv[4]
  end

  test "removes a worktree, forcing and deleting the branch only when asked" do
    orca = FakeOrca.new(ok({}), ok({}))
    c = client(orca)
    worktree = Harbor::Orca::Worktree.new(**WORKTREE.transform_keys(&:to_sym))
    assert c.remove_worktree(worktree)
    assert_equal %w[orca worktree rm --worktree id:repo-1::/work/spaces/run-7 --json], orca.argv
    c.remove_worktree(worktree, force: true, delete_branch: true)
    assert_equal %w[orca worktree rm --worktree id:repo-1::/work/spaces/run-7 --force --delete-branch --json], orca.argv
  end

  test "starts a command in a terminal of the worktree" do
    orca = FakeOrca.new(ok("terminal" => { "handle" => "term_1", "worktreeId" => WORKTREE["id"] }))
    terminal = client(orca).start_terminal(worktree: "/work/spaces/run-7", command: "run-agent 7; exit", title: "run 7")
    assert_equal [ "orca", "terminal", "create", "--worktree", "path:/work/spaces/run-7", "--command", "run-agent 7; exit",
                   "--title", "run 7", "--json" ], orca.argv
    assert_equal "term_1", terminal.handle
  end

  test "waiting reports an exit, and gives the command longer than the wait" do
    orca = FakeOrca.new(ok("wait" => { "satisfied" => true, "status" => "exited", "exitCode" => 0 }))
    result = client(orca).wait_for_exit("term_1", timeout: 30)
    assert result.exited?
    assert_equal %w[orca terminal wait --terminal term_1 --for exit --timeout-ms 30000 --json], orca.argv
    assert_operator orca.calls.last[:timeout], :>, 30
  end

  test "a wait that runs out means still running, not an error" do
    orca = FakeOrca.new(refused("timeout"))
    result = client(orca).wait_for_exit("term_1", timeout: 1.5)
    assert_not result.exited?
    assert_equal "running", result.status
    assert_equal "1500", orca.argv[orca.argv.index("--timeout-ms") + 1]
  end

  test "an exit carries no exit code, because Orca's is not the command's" do
    assert_not_includes Harbor::Orca::Exit.members, :exit_code
  end

  test "closing a terminal that is already gone is not an error" do
    orca = FakeOrca.new(ok({}), refused("terminal_handle_stale"))
    c = client(orca)
    assert_equal true, c.close_terminal(Harbor::Orca::Terminal.new(handle: "term_1"))
    assert_equal false, c.close_terminal("term_1")
  end

  test "a refusal raises with Orca's code and its first next step" do
    orca = FakeOrca.new(refused("selector_not_found", "selector" => "path:/nope", "nextSteps" => [ "No Orca workspace matched." ]))
    error = assert_raises(Harbor::Orca::Error) { client(orca).worktree("/nope") }
    assert_equal "selector_not_found", error.code
    assert_equal "path:/nope", error.data["selector"]
    assert_equal "orca worktree show: selector_not_found. No Orca workspace matched.", error.message
  end

  test "other refusals from wait and close are raised" do
    assert_raises(Harbor::Orca::Error) { client(FakeOrca.new(refused("terminal_handle_stale"))).wait_for_exit("t", timeout: 1) }
    assert_raises(Harbor::Orca::Error) { client(FakeOrca.new(refused("not_allowed"))).close_terminal("t") }
  end

  test "output that isn't Orca's JSON is an error that quotes it" do
    orca = FakeOrca.new([ "", "Orca is updating, try again\n", 78 ])
    error = assert_raises(Harbor::Orca::Error) { client(orca).status }
    assert_equal "orca_unreadable", error.code
    assert_match "exit 78", error.message
    assert_match "Orca is updating", error.message
  end

  test "a missing orca command says so" do
    error = assert_raises(Harbor::Orca::Error) { Harbor::Orca::Client.new(bin: "/nonexistent/orca").status }
    assert_equal "orca_missing", error.code
  end

  test "runs the real command line, and gives up on one that hangs" do
    Dir.mktmpdir("fake-orca") do |dir|
      bin = File.join(dir, "orca")
      File.write(bin, <<~SH)
        #!/bin/sh
        if [ "$1" = "status" ]; then echo '{"ok":true,"result":{"runtime":{"appVersion":"9.9.9","state":"ready"}}}'; exit 0; fi
        sleep 30
      SH
      File.chmod(0o755, bin)
      real = Harbor::Orca::Client.new(bin: bin)
      assert_equal "9.9.9", real.status[:version]

      stub_const = Harbor::Orca::Client::DEFAULT_TIMEOUT
      Harbor::Orca::Client.send(:remove_const, :DEFAULT_TIMEOUT)
      Harbor::Orca::Client.const_set(:DEFAULT_TIMEOUT, 0.5)
      begin
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        error = assert_raises(Harbor::Orca::Error) { real.close_terminal("term_1") }
        assert_equal "orca_timeout", error.code
        assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 10
      ensure
        Harbor::Orca::Client.send(:remove_const, :DEFAULT_TIMEOUT)
        Harbor::Orca::Client.const_set(:DEFAULT_TIMEOUT, stub_const)
      end
    end
  end

  test "the command line defaults to the configured one" do
    assert_equal "orca", Harbor.config.orca_bin
  end
end
