require "test_helper"

# How one step of a recipe is run: through sh from a folder, stdin given,
# stdout kept, stderr handed on line by line, and its whole process group
# stopped when it overruns or is told to stop. Real small scripts throughout.
class HarborMachinesScriptTest < ActiveSupport::TestCase
  Script = Harbor::Machines::Script

  setup { @dir = Dir.mktmpdir("harbor-script") }
  teardown { FileUtils.remove_entry(@dir) }

  def alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH
    false
  end

  test "a step runs through sh from the folder, with the environment added, stdin given, stdout kept and stderr handed on" do
    lines = []
    result = Script.run(%(echo "in $(pwd) as $ORCA_VM_MODE" >&2; echo "second" >&2; cat; echo " and $HOME"), chdir: @dir,
                        env: { "ORCA_VM_MODE" => "destroy" }, stdin: %({"instanceId":"i-1"}\n), on_stderr: ->(line) { lines << line })
    assert result.ok?
    assert_equal [ 0, false, false ], [ result.exit_status, result.timed_out, result.stopped ]
    assert_equal %({"instanceId":"i-1"}\n and #{ENV['HOME']}\n), result.stdout, "its own environment is passed through"
    assert_equal [ "in #{File.realpath(@dir)} as destroy", "second" ], lines
  end

  test "a step that fails says how" do
    result = Script.run("echo nope >&2; exit 7", chdir: @dir)
    assert_not result.ok?
    assert_equal 7, result.exit_status
  end

  test "a step that runs past its time is stopped with everything it started" do
    started = Time.current
    result = Script.run(%(sleep 300 & echo $! > "#{@dir}/child"; sleep 300 & echo $! > "#{@dir}/second"; wait), chdir: @dir, timeout: 0.5)
    assert result.timed_out
    assert_nil result.exit_status
    assert_operator Time.current - started, :<, 10
    children = %w[child second].map { |name| File.read(File.join(@dir, name)).to_i }
    sleep 0.2
    assert_equal [ false, false ], children.map { |pid| alive?(pid) }, "the whole process group is stopped, not only the shell"
  end

  test "a step that ignores TERM is killed" do
    result = Script.run(%(trap '' TERM; echo ready >&2; while true; do sleep 1; done), chdir: @dir, timeout: 0.3)
    assert result.timed_out
  end

  test "a caller can stop a step from its heartbeat" do
    beats = 0
    result = Script.run("sleep 300", chdir: @dir, tick: 0.1, on_tick: -> { (beats += 1) >= 2 ? :stop : nil })
    assert result.stopped
    assert_equal 2, beats
  end

  test "an exception in the caller leaves nothing running" do
    pid = nil
    assert_raises(Interrupt) do
      Script.run(%(sleep 300 & echo $! > "#{@dir}/child"; wait), chdir: @dir, tick: 0.2, on_spawn: ->(spawned) { pid = spawned }, on_tick: -> { raise Interrupt })
    end
    sleep 0.2
    assert_not alive?(File.read(File.join(@dir, "child")).to_i)
    assert_not alive?(pid)
  end
end
