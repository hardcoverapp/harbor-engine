require "json"
require "open3"
require "timeout"

module Harbor
  module Orca
    # A command Orca refused, or one that could not be run at all. `code` is
    # Orca's own error code ("selector_not_found", "terminal_handle_stale"…),
    # or one of ours: "orca_missing", "orca_timeout", "orca_unreadable".
    class Error < StandardError
      attr_reader :code, :data

      def initialize(message, code:, data: nil)
        super(message)
        @code = code
        @data = data || {}
      end
    end

    Worktree = Struct.new(:id, :path, :branch, keyword_init: true)
    Terminal = Struct.new(:handle, :worktree_id, keyword_init: true)
    # Whether a terminal's command has finished. Orca does not report how: with
    # 1.4.250 its exit code is 0 for a command that exited 3, so there is none
    # here. A run reports its own result to Harbor.
    Exit = Struct.new(:exited, :status, keyword_init: true) do
      def exited? = exited
    end

    # Talks to one Orca server through the `orca` command line, which is
    # already a network client: `environment` names a server paired with this
    # machine (`orca environment add`), and nil means the Orca on this machine.
    #
    # Everything Harbor asks of Orca goes through here, so a change in Orca's
    # commands, or a move to an API, is a change to this class only. The
    # commands and reply shapes were checked against Orca 1.4.250.
    class Client
      DEFAULT_TIMEOUT = 60

      attr_reader :environment

      # `runner` takes (argv, timeout:) and returns [stdout, stderr, exit
      # status]; tests pass their own, or set Harbor::Orca.runner.
      def initialize(environment: nil, bin: Harbor.config.orca_bin, runner: nil)
        @environment = environment.presence
        @bin = bin
        @runner = runner || Harbor::Orca.runner || method(:run)
      end

      # The server's version and whether it can take work.
      def status
        runtime = call("status").fetch("runtime", {})
        { version: runtime["appVersion"], ready: runtime["state"] == "ready" && runtime["reachable"] != false }
      end

      # A new worktree of `repo` (an Orca repo selector: "id:…", "name:…" or
      # "path:…"), branched from `base`. `setup` is whether the repository's
      # own setup hooks run: "run", "skip" or "inherit".
      def create_worktree(repo:, name:, base: nil, setup: "skip")
        args = [ "worktree", "create", "--repo", repo, "--name", name, "--setup", setup ]
        args += [ "--base-branch", base ] if base.present?
        worktree(call(*args, timeout: 300).fetch("worktree"))
      end

      def worktree(found)
        found = call("worktree", "show", "--worktree", selector(found)).fetch("worktree") unless found.is_a?(Hash)
        Worktree.new(id: found["id"], path: found["path"].presence || found["id"].to_s.split("::", 2).last, branch: found["branch"])
      end

      # Removes the worktree from Orca and git. `force` also removes one with
      # uncommitted changes. The branch is left unless `delete_branch`.
      def remove_worktree(worktree, force: false, delete_branch: false)
        args = [ "worktree", "rm", "--worktree", selector(worktree) ]
        args << "--force" if force
        args << "--delete-branch" if delete_branch
        call(*args, timeout: 300)
        true
      end

      # Starts `command` in a new terminal of the worktree and returns at
      # once. The terminal belongs to this client's server: wait for it and
      # close it through a client for the same environment.
      def start_terminal(worktree:, command:, title: nil)
        args = [ "terminal", "create", "--worktree", selector(worktree), "--command", command ]
        args += [ "--title", title ] if title.present?
        terminal = call(*args).fetch("terminal")
        Terminal.new(handle: terminal["handle"], worktree_id: terminal["worktreeId"])
      end

      # Waits up to `timeout` seconds for the terminal's command to exit.
      # Returns with `exited?` false when it is still running after that.
      def wait_for_exit(terminal, timeout:)
        milliseconds = (timeout * 1000).to_i
        wait = call("terminal", "wait", "--terminal", handle(terminal), "--for", "exit",
                    "--timeout-ms", milliseconds.to_s, timeout: timeout + DEFAULT_TIMEOUT).fetch("wait")
        Exit.new(exited: wait["satisfied"] == true && wait["status"] == "exited", status: wait["status"])
      rescue Error => e
        raise unless e.code == "timeout"
        Exit.new(exited: false, status: "running")
      end

      # Stops whatever the terminal is running and closes it. Closing one
      # that is already gone is not an error.
      def close_terminal(terminal)
        call("terminal", "close", "--terminal", handle(terminal))
        true
      rescue Error => e
        raise unless e.code == "terminal_handle_stale"
        false
      end

      private
        def selector(worktree)
          case worktree
          when Worktree then "id:#{worktree.id}"
          when /\A(id|path|name|branch|identity|issue):/ then worktree
          when %r{\A/} then "path:#{worktree}"
          else "id:#{worktree}"
          end
        end

        def handle(terminal) = terminal.respond_to?(:handle) ? terminal.handle : terminal.to_s

        # Runs one orca command and returns its `result`. Orca answers every
        # --json command with { ok:, result: | error: }.
        def call(*args, timeout: DEFAULT_TIMEOUT)
          argv = [ @bin, *args, "--json" ]
          argv += [ "--environment", @environment ] if @environment
          stdout, stderr, exit_status = @runner.call(argv, timeout: timeout)

          reply = parse(stdout)
          if reply.nil?
            detail = stderr.to_s.strip.presence || stdout.to_s.strip.presence || "no output"
            raise Error.new("orca #{args.first(2).join(' ')} gave no readable answer (exit #{exit_status}): #{detail.first(300)}",
                            code: "orca_unreadable")
          end
          return reply["result"] || {} if reply["ok"]

          error = reply["error"].is_a?(Hash) ? reply["error"] : { "message" => reply["error"].to_s }
          code = error["code"].presence || "orca_error"
          steps = Array(error.dig("data", "nextSteps")).first
          raise Error.new([ "orca #{args.first(2).join(' ')}: #{error['message'].presence || code}", steps ].compact.join(". "),
                          code: code, data: error["data"])
        end

        def parse(stdout)
          parsed = JSON.parse(stdout.to_s)
          parsed if parsed.is_a?(Hash) && parsed.key?("ok")
        rescue JSON::ParserError
          nil
        end

        # Reads a pipe to its end; one that is closed under it (the command
        # was killed for taking too long) reads as empty.
        def reader(io)
          Thread.new do
            Thread.current.report_on_exception = false
            io.read
          rescue IOError
            ""
          end
        end

        def run(argv, timeout:)
          Open3.popen3(*argv) do |stdin, stdout, stderr, thread|
            stdin.close
            out = reader(stdout)
            err = reader(stderr)
            unless thread.join(timeout)
              Process.kill("TERM", thread.pid) rescue nil
              thread.join(5) || (Process.kill("KILL", thread.pid) rescue nil)
              raise Error.new("orca #{argv[1, 2].join(' ')} did not answer within #{timeout}s", code: "orca_timeout")
            end
            [ out.value, err.value, thread.value.exitstatus ]
          end
        rescue Errno::ENOENT
          raise Error.new("The orca command (#{argv.first}) isn't installed where Harbor runs.", code: "orca_missing")
        end
    end
  end
end
