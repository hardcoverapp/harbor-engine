require "test_helper"

class HarborLiveLogTest < ActiveSupport::TestCase
  setup do
    @dir = Dir.mktmpdir("harbor-logs")
    @location = Harbor.config.log_location
    @path = Harbor.config.log_path
    Harbor.config.log_location = ->(path) { File.join(@dir, path) }
    Harbor::Run.delete_all
  end

  teardown do
    Harbor.config.log_location = @location
    Harbor.config.log_path = @path
    FileUtils.rm_rf(@dir)
  end

  test "a run's log is named for its kind of work, and each model attempt gets its own" do
    assert_equal "db-backup/run-7.log", Harbor::Run.new(id: 7, loader: "db-backup").live_log_path
    assert_equal "workflow-review-ask/run-8.log", Harbor::Run.new(id: 8, skill: "workflow.review.ask").live_log_path
    assert_equal "review/run-9-attempt-2.log", Harbor::Run.new(id: 9, skill: "review", input: { "model_switches" => [ {} ] }).live_log_path
    assert_nil Harbor::Run.new(id: 10, agent_key: "ada").live_log_path
  end

  test "the host can name logs its own way" do
    Harbor.config.log_path = ->(run) { "runs/#{run.id}.md" }
    assert_equal "runs/7.md", Harbor::Run.new(id: 7, agent_key: "ada").live_log_path
  end

  test "by default logs live under storage" do
    Harbor.config.log_location = @location
    assert_equal Rails.root.join("storage/harbor/logs/a/b.log").to_s, Harbor::LiveLog.absolute("a/b.log")
    assert_equal Rails.root.join("storage/harbor/logs/a/b.log").to_s, Harbor::LiveLog.absolute("/a/b.log")
  end

  test "open appends lines between start and finish marks, and read returns them" do
    log = Harbor::LiveLog.open("fetch/run-1.log")
    log.call("fetching posts")
    log.call("done: 3")
    Harbor::LiveLog.close(log)

    body = Harbor::LiveLog.read("fetch/run-1.log")
    assert_match(/<!-- run started at .+ -->\n\nfetching posts\ndone: 3\n\n<!-- run finished at .+ -->\n\z/, body)
    assert Harbor::LiveLog.exist?("fetch/run-1.log")
  end

  test "a second open appends to the same log" do
    2.times do |n|
      log = Harbor::LiveLog.open("fetch/run-1.log")
      log.call("pass #{n}")
      Harbor::LiveLog.close(log)
    end
    assert_equal 2, Harbor::LiveLog.read("fetch/run-1.log").scan("run started").size
  end

  test "a line written after the log is closed is dropped, not raised" do
    log = Harbor::LiveLog.open("fetch/run-2.log")
    Harbor::LiveLog.close(log)
    assert_nothing_raised { log.call("late") }
    assert_no_match(/late/, Harbor::LiveLog.read("fetch/run-2.log"))
  end

  test "a run with no log path has no log" do
    assert_nil Harbor::LiveLog.open(nil)
    assert_nil Harbor::LiveLog.read(nil)
    assert_nil Harbor::LiveLog.tail("nothing/here.log")
    assert_not Harbor::LiveLog.exist?("")
    assert_nothing_raised { Harbor::LiveLog.close(nil) }
  end

  test "tail returns a short log whole" do
    File.write(Harbor::LiveLog.absolute("short.log").tap { |f| FileUtils.mkdir_p(File.dirname(f)) }, "one\ntwo\n")
    assert_equal({ body: "one\ntwo\n", clipped: false }, Harbor::LiveLog.tail("short.log"))
  end

  test "tail of a long log is its end, starting at a whole line" do
    lines = (1..2000).map { |n| "line #{n} of the log" }
    File.write(Harbor::LiveLog.absolute("long.log"), lines.join("\n") + "\n")
    tail = Harbor::LiveLog.tail("long.log", bytes: 1000)
    assert tail[:clipped]
    assert_operator tail[:body].bytesize, :<=, 1000
    assert_match(/\Aline \d+ of the log\n/, tail[:body])
    assert tail[:body].end_with?("line 2000 of the log\n")
  end

  test "tail survives a cut through the middle of a character" do
    File.write(Harbor::LiveLog.absolute("utf.log"), "é" * 600 + "\nlast line\n")
    tail = Harbor::LiveLog.tail("utf.log", bytes: 301)
    assert tail[:body].valid_encoding?
    assert tail[:body].end_with?("last line\n")
  end
end
