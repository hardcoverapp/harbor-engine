module Harbor
  module Machines
    # Runs one step of a recipe the way Orca runs it: the command line through
    # `sh -c`, from the folder the recipe is declared in, in a process group
    # of its own, with the lifecycle JSON (if any) on its stdin. Its stdout is
    # kept, for the one JSON object a step may print; each line of its stderr
    # is handed on as it arrives. A step that runs past its time, or that is
    # told to stop, has its whole process group stopped: TERM, then KILL
    # after Orca's five seconds.
    #
    # Nothing here touches the database. `on_tick` is called every `tick`
    # seconds while the step runs (a caller's heartbeat); when it returns
    # :stop the step is stopped.
    class Script
      Result = Struct.new(:stdout, :exit_status, :timed_out, :stopped, :overflowed, keyword_init: true) do
        def ok? = exit_status == 0 && !timed_out && !stopped
      end

      # As much stdout as Orca keeps.
      CAPTURE = 1.megabyte
      GRACE = 5
      # How long the pipes are read after the command itself has exited, for
      # something it left running that still holds them.
      DRAIN = 2

      def self.run(command, **options) = new(command, **options).run

      def initialize(command, chdir:, env: {}, stdin: nil, timeout: nil, tick: 5, on_stderr: nil, on_tick: nil, on_spawn: nil)
        @command = command
        @chdir = chdir
        @env = env
        @stdin = stdin
        @timeout = timeout
        @tick = tick
        @on_stderr = on_stderr
        @on_tick = on_tick
        @on_spawn = on_spawn
      end

      def run
        in_r, in_w = IO.pipe
        out_r, out_w = IO.pipe
        err_r, err_w = IO.pipe
        pid = Process.spawn(@env, "/bin/sh", "-c", @command, chdir: @chdir, pgroup: true, in: in_r, out: out_w, err: err_w, close_others: true)
        [ in_r, out_w, err_w ].each(&:close)
        waiter = Process.detach(pid)
        @on_spawn&.call(pid)

        writer = Thread.new { write_stdin(in_w) }
        stdout = +"".b
        overflowed = false
        readers = [
          Thread.new { read_all(out_r) { |bytes| stdout.bytesize < CAPTURE ? stdout << bytes.byteslice(0, CAPTURE - stdout.bytesize) : overflowed = true } },
          Thread.new { read_lines(err_r) }
        ]

        timed_out, stopped = wait(waiter)
        stop_group(pid, waiter) if timed_out || stopped
        readers.each { |reader| reader.join(DRAIN) }
        Result.new(stdout: stdout.force_encoding(Encoding::UTF_8).scrub("?"), exit_status: (waiter.value&.exitstatus unless timed_out || stopped),
                   timed_out:, stopped:, overflowed:)
      ensure
        # Left by an exception (the job's worker is shutting down): nothing
        # the step started may outlive this call.
        stop_group(pid, waiter) if pid && waiter&.alive?
        [ writer, *readers ].compact.each(&:kill)
        [ in_w, out_r, err_r ].compact.each { |io| io.close rescue nil }
      end

      private

      # [timed out, stopped]: both false when the command ended by itself.
      def wait(waiter)
        started = monotonic
        ticked = started
        loop do
          return [ false, false ] if waiter.join(0.05)
          now = monotonic
          return [ true, false ] if @timeout && now - started >= @timeout
          next unless @on_tick && now - ticked >= @tick
          ticked = now
          return [ false, true ] if @on_tick.call == :stop
        end
      end

      def stop_group(pid, waiter)
        signal("TERM", pid)
        deadline = monotonic + GRACE
        sleep 0.05 while (waiter.alive? || group_alive?(pid)) && monotonic < deadline
        return unless waiter.alive? || group_alive?(pid)
        signal("KILL", pid)
        waiter.join(GRACE)
      end

      # The whole group: the command and everything it started.
      def signal(name, pid)
        Process.kill(name, -pid)
      rescue Errno::ESRCH, Errno::EPERM
        nil
      end

      def group_alive?(pid)
        Process.kill(0, -pid)
        true
      rescue Errno::ESRCH, Errno::EPERM
        false
      end

      def write_stdin(io)
        io.write(@stdin) if @stdin
      rescue Errno::EPIPE, IOError
        nil
      ensure
        io.close rescue nil
      end

      def read_all(io)
        loop { yield io.readpartial(64.kilobytes) }
      rescue EOFError, IOError
        nil
      end

      def read_lines(io)
        io.each_line { |line| @on_stderr&.call(line.force_encoding(Encoding::UTF_8).scrub("?").chomp) }
      rescue IOError
        nil
      end

      def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
