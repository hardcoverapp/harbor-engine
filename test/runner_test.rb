require "test_helper"
require "open3"
require "tmpdir"

class HarborRunnerTest < ActionDispatch::IntegrationTest
  include HarborTestConfig

  # Stands in for the orca command, as in the client's own tests.
  class FakeOrca
    attr_reader :calls

    def initialize(*replies)
      @replies = replies
      @calls = []
    end

    def call(argv, timeout:)
      @calls << argv
      reply = @replies.shift or raise "no reply queued for #{argv.inspect}"
      [ JSON.generate(reply), "", reply["ok"] ? 0 : 1 ]
    end
  end

  setup do
    Harbor::Run.delete_all
    Harbor::Runtime.delete_all
    Harbor::Setting.set!(:runner_url, "https://harbor.example.com/")
    @logs = Dir.mktmpdir
    @log_location = Harbor.config.log_location
    Harbor.config.log_location = ->(path) { File.join(@logs, path) }
    @run = Harbor::Run.create!(skill: "writer.fix", status: "running", started_at: Time.current)
    @token = Harbor::RunToken.generate(@run)
  end

  teardown do
    Harbor.config.log_location = @log_location
    Harbor.config.run_reported = nil
    FileUtils.remove_entry(@logs)
  end

  def auth(token = @token) = { "Authorization" => "Bearer #{token}" }

  test "a token is good for its own run, for a limited time" do
    other = Harbor::Run.create!(skill: "writer.other", status: "running")
    assert Harbor::RunToken.valid?(@token, @run.id)
    assert_not Harbor::RunToken.valid?(@token, other.id)
    assert_not Harbor::RunToken.valid?("nonsense", @run.id)
    assert_not Harbor::RunToken.valid?(nil, @run.id)
    travel(Harbor::RunToken::LIFETIME + 1.minute) { assert_not Harbor::RunToken.valid?(@token, @run.id) }
  end

  def log_post(body, offset: nil, run: @run, **query)
    query = { offset: }.merge(query).compact.to_query
    post "/harbor/runner/runs/#{run.id}/log#{"?#{query}" if query.present?}", params: body,
         headers: auth(Harbor::RunToken.generate(run)).merge("Content-Type" => "application/octet-stream")
  end

  def log_bytes(run = @run) = File.binread(Harbor::LiveLog.absolute(run.live_log_path))

  test "a runner appends to its run's log in pieces, exactly as sent" do
    log_post "first line\nhalf a ", offset: 0
    assert_response :no_content
    log_post "line\n", offset: 18
    assert_response :no_content
    assert_equal "first line\nhalf a line\n", Harbor::LiveLog.read(@run.live_log_path)
    assert_equal 23, @run.reload.runner_state["received"]
    assert @run.runner_state["last_seen_at"].present?
  end

  test "a piece sent twice is kept once, and one that overlaps adds only what is new" do
    log_post "one\n", offset: 0
    log_post "one\n", offset: 0
    assert_response :no_content, "a repeat is accepted, so the runner moves on"
    assert_equal "one\n", log_bytes

    log_post "e\ntwo\n", offset: 2
    assert_response :no_content
    assert_equal "one\ntwo\n", log_bytes
    assert_equal 8, @run.reload.runner_state["received"]
  end

  test "a piece that leaves a gap is refused with what Harbor has, and nothing is written" do
    log_post "one\n", offset: 0
    log_post "three\n", offset: 9
    assert_response :conflict
    assert_equal "4", response.body
    assert_equal "one\n", log_bytes

    log_post "two\nthree\n", offset: 4
    assert_response :no_content
    assert_equal "one\ntwo\nthree\n", log_bytes
  end

  test "bytes are kept as they arrive, so a character split across two pieces survives" do
    word = "café\n".b
    log_post word.byteslice(0, 4), offset: 0
    log_post word.byteslice(4, 2), offset: 4
    assert_equal word, log_bytes
    assert_equal "café\n", Harbor::LiveLog.read(@run.live_log_path)

    log_post "\xFF\xFEbad\n".b, offset: 6
    assert_equal "\xFF\xFEbad\n".b, log_bytes.byteslice(6, 6), "bytes that aren't text are still kept"
    assert_equal "café\n??bad\n", Harbor::LiveLog.read(@run.live_log_path), "and only made text where a person reads them"
  end

  test "a runner that says no offset is taken to be sending the next piece" do
    log_post "one\n"
    log_post "two\n"
    assert_equal "one\ntwo\n", log_bytes
  end

  test "an offset that isn't a count is refused" do
    log_post "x", offset: "soon"
    assert_response :unprocessable_entity
    log_post "x", offset: -1
    assert_response :unprocessable_entity
    assert_nil Harbor::LiveLog.read(@run.live_log_path)
  end

  test "a finished run takes no more output" do
    @run.finish!(status: "ok")
    log_post "late\n", offset: 0
    assert_response :conflict
    assert_equal "finished", response.body
    assert_nil Harbor::LiveLog.read(@run.live_log_path)
  end

  test "the endpoints need the run's own token, and no login" do
    other = Harbor::Run.create!(skill: "writer.other", status: "running")
    post "/harbor/runner/runs/#{@run.id}/log", params: "x", headers: { "Content-Type" => "text/plain" }
    assert_response :unauthorized
    post "/harbor/runner/runs/#{@run.id}/log", params: "x", headers: auth(Harbor::RunToken.generate(other)).merge("Content-Type" => "text/plain")
    assert_response :unauthorized
    post "/harbor/runner/runs/#{@run.id}/result", params: { exit_status: 0 }, headers: auth("forged"), as: :json
    assert_response :unauthorized
    post "/harbor/runner/runs/#{@run.id}/bundle/env", headers: auth(Harbor::RunToken.generate(other))
    assert_response :unauthorized
    assert_nil Harbor::LiveLog.read(@run.live_log_path)
    assert @run.reload.running?
  end

  test "an oversized piece is refused" do
    log_post "x" * (Harbor::Runner::RunsController::MAX_CHUNK + 1), offset: 0
    assert_response :content_too_large
  end

  test "a reported exit status finishes the run" do
    post "/harbor/runner/runs/#{@run.id}/result", params: { exit_status: 0 }, headers: auth, as: :json
    assert_response :no_content
    assert @run.reload.ok?

    failed = Harbor::Run.create!(skill: "writer.fail", status: "running")
    post "/harbor/runner/runs/#{failed.id}/result", params: { exit_status: 3 }, headers: auth(Harbor::RunToken.generate(failed)), as: :json
    assert failed.reload.error?
    assert_equal "The command exited with status 3.", failed.error

    post "/harbor/runner/runs/#{failed.id}/result", params: { exit_status: 0 }, headers: auth(Harbor::RunToken.generate(failed)), as: :json
    assert_response :no_content
    assert failed.reload.error?, "a finished run is left as it was"
    post "/harbor/runner/runs/#{@run.id}/result", params: { exit_status: "soon" }, headers: auth, as: :json
    assert_response :unprocessable_entity
  end

  test "a host can take the report itself, and is told once" do
    seen = []
    Harbor.config.run_reported = ->(run, exit_status:) { seen << [ run.id, exit_status ] }
    post "/harbor/runner/runs/#{@run.id}/result", params: { exit_status: 143, signalled: true }, headers: auth, as: :json
    assert_equal [ [ @run.id, 143 ] ], seen
    assert @run.reload.running?, "finishing is the host's now"
    assert_equal({ "reported" => true, "exit_status" => 143, "signalled" => true }, @run.runner_state.slice("reported", "exit_status", "signalled"))

    post "/harbor/runner/runs/#{@run.id}/result", params: { exit_status: 0 }, headers: auth, as: :json
    assert_response :no_content
    assert_equal 1, seen.size, "a second report changes nothing"
    assert_equal 143, @run.reload.runner_state["exit_status"]
  end

  test "a report for a run Harbor already finished is not passed on" do
    seen = []
    Harbor.config.run_reported = ->(run, exit_status:) { seen << exit_status }
    @run.finish!(status: "canceled")
    post "/harbor/runner/runs/#{@run.id}/result", params: { exit_status: 0 }, headers: auth, as: :json
    assert_response :no_content
    assert_empty seen
    assert @run.reload.canceled?
  end

  test "a plain run has no files to fetch" do
    post "/harbor/runner/runs/#{@run.id}/bundle/prompt", headers: auth
    assert_response :not_found
    post "/harbor/runner/runs/#{@run.id}/bundle/passwd", headers: auth
    assert_response :not_found
  end

  test "the runner command carries the run's address, its token and the script" do
    line = Harbor::Runner.command_for(@run, "echo 'hi there'")
    words = Shellwords.split(line)
    assert_equal "HARBOR_RUNNER_URL=https://harbor.example.com/harbor/runner/runs/#{@run.id}", words[0]
    assert Harbor::RunToken.valid?(words[1].delete_prefix("HARBOR_RUNNER_TOKEN="), @run.id)
    assert_equal [ "sh", "-c", Harbor::Runner::SCRIPT, "harbor-runner", "echo 'hi there'" ], words[2..]

    words = Shellwords.split(Harbor::Runner.command_for(@run, "true", bundle: %w[prompt env], attempt: 2))
    assert_equal [ "HARBOR_RUNNER_BUNDLE=prompt env", "HARBOR_RUNNER_ATTEMPT=2", "sh" ], words[2, 3]

    Harbor::Setting.set!(:runner_url, "")
    assert_raises(Harbor::Runner::NoAddress) { Harbor::Runner.command_for(@run, "true") }
  end

  # --- The script itself, run for real, with a curl that keeps what it is
  # sent in files instead of the network (test/support/fake_curl.sh). ---

  FAKE_CURL = File.expand_path("support/fake_curl.sh", __dir__)
  # The shells a runner machine's `sh` is likely to be, of those here.
  SHELLS = ([ "sh" ] + %w[/bin/dash /bin/bash].select { |shell| File.executable?(shell) }).freeze

  Ran = Struct.new(:status, :log, :results, :posts, :argv, :left_behind, :files, keyword_init: true)

  # Runs the script around `command`. `bundle` is the run's files as the
  # stand-in serves them; `stop_after` sends the script that signal after
  # that many seconds; the block gets the stand-in's folder first, to steer it.
  def run_script(command, shell: "sh", bundle: {}, env: {}, stop_after: nil, signal: "TERM")
    Dir.mktmpdir do |dir|
      %w[bin bundle tmp].each { |name| FileUtils.mkdir_p(File.join(dir, name)) }
      FileUtils.cp(FAKE_CURL, File.join(dir, "bin/curl"))
      File.chmod(0o755, File.join(dir, "bin/curl"))
      bundle.each { |name, body| File.write(File.join(dir, "bundle", name), body) }
      yield dir if block_given?
      env = { "PATH" => "#{dir}/bin:#{ENV['PATH']}", "FAKE_CURL_DIR" => dir, "TMPDIR" => File.join(dir, "tmp"),
              "HARBOR_RUNNER_URL" => "https://harbor.example.com/harbor/runner/runs/7", "HARBOR_RUNNER_TOKEN" => "run-token",
              "HARBOR_RUNNER_GRACE" => "1" }.merge(env)
      pid = Process.spawn(env, shell, "-c", Harbor::Runner::SCRIPT, "harbor-runner", command, out: File::NULL, err: File::NULL)
      if stop_after
        sleep stop_after
        Process.kill(signal, pid)
      end
      _, status = Process.wait2(pid)
      read = ->(name) { File.exist?(File.join(dir, name)) ? File.binread(File.join(dir, name)) : "" }
      Ran.new(status: status.exitstatus, log: read.call("log"), results: read.call("result").lines(chomp: true),
              posts: read.call("posts").lines.map { |line| line.split.map(&:to_i) }, argv: read.call("argv"),
              left_behind: Dir.children(File.join(dir, "tmp")),
              files: Dir.children(dir).to_h { |name| [ name, File.file?(File.join(dir, name)) ? read.call(name) : nil ] })
    end
  end

  def alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH
    false
  end

  test "the script is valid sh" do
    Tempfile.create("harbor-runner") do |file|
      file.write(Harbor::Runner::SCRIPT)
      file.flush
      SHELLS.each { |shell| assert system(shell, "-n", file.path), "#{shell} -n refused the script" }
    end
  end

  SHELLS.each do |shell|
    test "the script sends everything the command prints, then its exit status, and exits with it (#{shell})" do
      ran = run_script("echo one; sleep 1.2; echo two >&2; printf 'no newline'; exit 3", shell:)

      assert_equal 3, ran.status
      assert_equal "one\ntwo\nno newline", ran.log
      assert_equal [ '{"exit_status":3,"signalled":false}' ], ran.results
      assert_operator ran.posts.size, :>=, 2, "output is sent as it comes, not only at the end"
      assert_match %r{/runs/7/result\s*\z}, ran.argv, "the result is the last thing sent"
      assert_empty ran.left_behind, "its scratch files are removed"
    end

    test "every post says where it starts, each one where the last ended (#{shell})" do
      ran = run_script("echo one; sleep 1.2; echo two; sleep 1.2; echo three", shell:)

      assert_equal "one\ntwo\nthree\n", ran.log
      expected = 0
      ran.posts.each do |offset, bytes|
        assert_equal expected, offset
        expected += bytes
      end
      assert_equal ran.posts.size, ran.argv.scan(%r{/log\?offset=\d+}).size, "and says so in the address"
    end

    test "a stopped script stops everything the command started, reports it and leaves nothing (#{shell})" do
      # The child ignores TERM: only KILL, after the grace period, ends it.
      command = %q(echo started; sh -c 'trap "" TERM; echo $$ > "$FAKE_CURL_DIR/child"; exec sleep 300' & sleep 300)
      ran = run_script(command, shell:, stop_after: 1.5)

      assert_equal 143, ran.status
      assert_equal [ '{"exit_status":143,"signalled":true}' ], ran.results
      assert_equal "started\n", ran.log, "what was printed before the stop still arrives"
      child = ran.files.fetch("child").to_i
      assert_operator child, :>, 0
      assert_not alive?(child), "the child that ignored TERM was killed"
      assert_empty ran.left_behind
    end
  end

  test "a closed terminal is a stop too" do
    ran = run_script("echo started; sleep 300", stop_after: 1.5, signal: "HUP")
    assert_equal [ '{"exit_status":143,"signalled":true}' ], ran.results
    assert_empty ran.left_behind
  end

  test "a post whose answer was lost is sent again from the same place, and nothing is doubled" do
    ran = run_script("echo one; sleep 2.4; echo two") { |dir| FileUtils.touch(File.join(dir, "lose-answer")) }

    assert_equal "one\ntwo\n", ran.log
    assert_operator ran.posts.count { |offset, _| offset.zero? }, :>=, 2, "the first piece was sent again, from offset 0"
  end

  test "a post Harbor refuses is sent again from Harbor's count" do
    # Harbor forgets the last byte it had (as after a failed write) and says
    # it has 3: the script goes back to 3 instead of carrying on from 4.
    ran = run_script(%q(echo one; sleep 2.4; echo 3 > "$FAKE_CURL_DIR/rewind"; echo two; sleep 2.4; echo three))

    assert_equal "one\ntwo\nthree\n", ran.log
    assert_includes ran.posts.map(&:first), 3
  end

  test "a large backlog goes out in pieces of at most 1 MB" do
    ran = run_script("head -c 2500000 /dev/zero | tr '\\0' 'x'")

    assert_equal 2_500_000, ran.log.bytesize
    assert_equal [ "x" ], ran.log.chars.uniq
    assert_operator ran.posts.size, :>=, 3
    assert ran.posts.all? { |_, bytes| bytes <= 1_048_576 }, "no post is over 1 MB: #{ran.posts.map(&:last).inspect}"
    assert_equal [ '{"exit_status":0,"signalled":false}' ], ran.results
  end

  test "the run's files are fetched into a private folder, and the environment reaches the command without being in any command line" do
    command = %q(echo "$(cat "$HARBOR_RUN_DIR/prompt") / $MODEL_CREDENTIAL / ${HARBOR_RUNNER_TOKEN:-no token}"; ls -ld "$HARBOR_RUN_DIR" | cut -c1-10)
    ran = run_script(command, env: { "HARBOR_RUNNER_BUNDLE" => "prompt env", "HARBOR_RUNNER_ATTEMPT" => "2" },
                              bundle: { "prompt" => "Fix it's \"test\"", "env" => "export MODEL_CREDENTIAL='s3cr3t value'\n" })

    assert_equal 0, ran.status
    assert_equal "Fix it's \"test\" / s3cr3t value / no token\ndrwx------\n", ran.log
    assert_not_includes ran.argv, "s3cr3t", "no command line carried the secret"
    assert_match %r{/runs/7/bundle/prompt\?attempt=2$}, ran.argv
    assert_match %r{/runs/7/bundle/env\?attempt=2$}, ran.argv
    assert_match %r{/log\?offset=0&attempt=2$}, ran.argv
    assert_match %r{/result\?attempt=2$}, ran.argv
    assert_empty ran.left_behind, "the folder and the files in it are removed"
  end

  test "a run whose files can't be fetched doesn't start its command, and says why" do
    ran = run_script(%q(touch "$FAKE_CURL_DIR/ran"), env: { "HARBOR_RUNNER_BUNDLE" => "prompt" })

    assert_equal 70, ran.status
    assert_not ran.files.key?("ran")
    assert_match "could not fetch this run's prompt from Harbor (HTTP 404)", ran.log
    assert_equal [ '{"exit_status":70,"signalled":false}' ], ran.results
    assert_empty ran.left_behind
  end

  test "when Harbor says the run is over, the script stops the command" do
    started = Time.current
    ran = run_script("echo working; sleep 300") { |dir| FileUtils.touch(File.join(dir, "finished")) }

    assert_operator Time.current - started, :<, 30
    assert_equal 143, ran.status
    assert_equal [ '{"exit_status":143,"signalled":false}' ], ran.results
    assert_empty ran.left_behind
  end

  test "the Orca backend makes a worktree and starts the wrapped command in a terminal there" do
    runtime = Harbor::Runtime.create!(key: "laptop", name: "Laptop", backend: "orca",
                                      config: { "repo" => "name:app", "environment" => "sam-laptop" })
    orca = FakeOrca.new(
      { "ok" => true, "result" => { "worktree" => { "id" => "r1::/w/harbor-run-#{@run.id}", "path" => "/w/harbor-run-#{@run.id}", "branch" => "b" } } },
      { "ok" => true, "result" => { "terminal" => { "handle" => "term-1", "worktreeId" => "r1::/w/harbor-run-#{@run.id}" } } },
      { "ok" => true, "result" => {} },
      { "ok" => true, "result" => {} })
    backend = runtime.adapter(client: Harbor::Orca::Client.new(bin: "orca", runner: orca, environment: "sam-laptop"))
    assert_nil runtime.unavailable_reason
    assert_equal "Laptop · sam-laptop", backend.runner_name

    session = backend.start(run: @run, command: "make test", base: "main")
    assert_equal({ "worktree_id" => "r1::/w/harbor-run-#{@run.id}", "worktree_path" => "/w/harbor-run-#{@run.id}", "terminal" => "term-1" }, session.to_h)
    create, terminal = orca.calls
    assert_equal [ "orca", "worktree", "create", "--repo", "name:app", "--name", "harbor-run-#{@run.id}", "--setup", "skip",
                   "--base-branch", "main", "--json", "--environment", "sam-laptop" ], create
    wrapped = terminal[terminal.index("--command") + 1]
    assert_equal "make test", Shellwords.split(wrapped).last
    assert_includes wrapped, "HARBOR_RUNNER_URL=https://harbor.example.com/harbor/runner/runs/#{@run.id}"

    restored = Harbor::Runtimes::Backends::Orca::Session.from(session.to_h)
    assert backend.stop(restored)
    assert backend.cleanup(restored)
    assert_equal %w[terminal close --terminal term-1], orca.calls[2][1, 4]
    assert_equal [ "worktree", "rm", "--worktree", "id:r1::/w/harbor-run-#{@run.id}", "--force", "--delete-branch" ], orca.calls[3][1, 6]
  end

  test "an Orca runtime isn't used until it has a repository and runners have an address" do
    runtime = Harbor::Runtime.create!(key: "bare", name: "Bare", backend: "orca")
    assert_match "no repository set", runtime.unavailable_reason
    runtime.update!(config: { "repo" => "name:app" })
    assert_nil runtime.unavailable_reason
    Harbor::Setting.set!(:runner_url, "")
    assert_match "no runner address set", runtime.unavailable_reason
  end

  test "a worktree whose terminal can't be started is removed again" do
    runtime = Harbor::Runtime.create!(key: "flaky", name: "Flaky", backend: "orca", config: { "repo" => "name:app" })
    orca = FakeOrca.new(
      { "ok" => true, "result" => { "worktree" => { "id" => "r1::/w/x", "path" => "/w/x", "branch" => "b" } } },
      { "ok" => false, "error" => { "code" => "runtime_unavailable", "message" => "no" } },
      { "ok" => true, "result" => {} })
    backend = runtime.adapter(client: Harbor::Orca::Client.new(bin: "orca", runner: orca))
    assert_raises(Harbor::Orca::Error) { backend.start(run: @run, command: "true") }
    assert_equal %w[worktree rm], orca.calls.last[1, 2]
  end
end
