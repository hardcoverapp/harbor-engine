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

  test "a runner appends to its run's log in pieces, exactly as sent" do
    post "/harbor/runner/runs/#{@run.id}/log", params: "first line\nhalf a ", headers: auth.merge("Content-Type" => "text/plain")
    assert_response :no_content
    post "/harbor/runner/runs/#{@run.id}/log", params: "line\n", headers: auth.merge("Content-Type" => "text/plain")
    assert_equal "first line\nhalf a line\n", Harbor::LiveLog.read(@run.live_log_path)
  end

  test "the endpoints need the run's own token, and no login" do
    other = Harbor::Run.create!(skill: "writer.other", status: "running")
    post "/harbor/runner/runs/#{@run.id}/log", params: "x", headers: { "Content-Type" => "text/plain" }
    assert_response :unauthorized
    post "/harbor/runner/runs/#{@run.id}/log", params: "x", headers: auth(Harbor::RunToken.generate(other)).merge("Content-Type" => "text/plain")
    assert_response :unauthorized
    post "/harbor/runner/runs/#{@run.id}/result", params: { exit_status: 0 }, headers: auth("forged"), as: :json
    assert_response :unauthorized
    assert_nil Harbor::LiveLog.read(@run.live_log_path)
    assert @run.reload.running?
  end

  test "an oversized piece is refused" do
    post "/harbor/runner/runs/#{@run.id}/log", params: "x" * (Harbor::Runner::RunsController::MAX_CHUNK + 1),
         headers: auth.merge("Content-Type" => "text/plain")
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
    assert failed.reload.error?, "a finished run is left as it was"
    post "/harbor/runner/runs/#{@run.id}/result", params: { exit_status: "soon" }, headers: auth, as: :json
    assert_response :unprocessable_entity
  end

  test "a host can take the report itself" do
    seen = []
    Harbor.config.run_reported = ->(run, exit_status:) { seen << [ run.id, exit_status ] }
    post "/harbor/runner/runs/#{@run.id}/result", params: { exit_status: 2 }, headers: auth, as: :json
    assert_equal [ [ @run.id, 2 ] ], seen
    assert @run.reload.running?, "finishing is the host's now"
  end

  test "the runner command carries the run's address, its token and the script" do
    line = Harbor::Runner.command_for(@run, "echo 'hi there'")
    words = Shellwords.split(line)
    assert_equal "HARBOR_RUNNER_URL=https://harbor.example.com/harbor/runner/runs/#{@run.id}", words[0]
    assert Harbor::RunToken.valid?(words[1].delete_prefix("HARBOR_RUNNER_TOKEN="), @run.id)
    assert_equal [ "sh", "-c", Harbor::Runner::SCRIPT, "harbor-runner", "echo 'hi there'" ], words[2..]

    Harbor::Setting.set!(:runner_url, "")
    assert_raises(Harbor::Runner::NoAddress) { Harbor::Runner.command_for(@run, "true") }
  end

  # The script itself, run for real with a curl that writes what it is sent
  # to files instead of the network.
  test "the script sends everything the command prints, then its exit status, and exits with it" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "curl"), <<~SH)
        #!/bin/sh
        # A stand-in for curl: appends each body to a file named for the URL's last part.
        body="" url=""
        while [ $# -gt 0 ]; do
          case "$1" in
            --data-binary) body="$2"; shift ;;
            --data) printf '%s' "$2" >> "#{dir}/result"; shift ;;
            -H|-m|--retry|-X) shift ;;
            http*) url="$1" ;;
          esac
          shift
        done
        case "$body" in @*) cat "${body#@}" >> "#{dir}/$(basename "$url")" ;; esac
        echo "$url" >> "#{dir}/urls"
      SH
      File.chmod(0o755, File.join(dir, "curl"))
      env = { "PATH" => "#{dir}:#{ENV['PATH']}", "HARBOR_RUNNER_URL" => "https://harbor.example.com/harbor/runner/runs/7",
              "HARBOR_RUNNER_TOKEN" => "t", "TMPDIR" => dir }
      command = "echo one; sleep 1.2; echo two >&2; printf 'no newline'; exit 3"
      _out, status = Open3.capture2e(env, "sh", "-c", Harbor::Runner::SCRIPT, "harbor-runner", command)

      assert_equal 3, status.exitstatus
      assert_equal "one\ntwo\nno newline", File.read(File.join(dir, "log"))
      assert_equal '{"exit_status":3}', File.read(File.join(dir, "result"))
      urls = File.readlines(File.join(dir, "urls"), chomp: true)
      assert_equal "https://harbor.example.com/harbor/runner/runs/7/result", urls.last
      assert_operator urls.count { |u| u.end_with?("/log") }, :>=, 2, "output is sent as it comes, not only at the end"
      assert_empty Dir.glob(File.join(dir, "harbor-run.*")), "its scratch files are removed"
    end
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
