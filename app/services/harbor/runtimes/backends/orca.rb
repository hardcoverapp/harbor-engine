module Harbor
  module Runtimes
    module Backends
      # An Orca server: the one beside Harbor, or one paired with this machine
      # (a teammate's computer, a cloud workspace). Orca makes the worktree; a
      # run is a command in an Orca terminal there, wrapped so it reports its
      # output and result back to Harbor (Harbor::Runner).
      #
      # The runtime's config:
      #   "repo"         the Orca repo selector work happens in ("name:app",
      #                  "path:/code/app", "id:…")
      #   "environment"  the paired server's name (`orca environment add`);
      #                  blank for the Orca on this machine
      #   "setup"        whether the repo's own setup hooks run in a new
      #                  worktree: "run", "skip" (default) or "inherit"
      class Orca < Harbor::Runtimes::Backend
        # What a started run holds on the server, to stop and clean up with.
        Session = Struct.new(:worktree_id, :worktree_path, :terminal, keyword_init: true) do
          def to_h = { "worktree_id" => worktree_id, "worktree_path" => worktree_path, "terminal" => terminal }
          def self.from(hash) = new(worktree_id: hash["worktree_id"], worktree_path: hash["worktree_path"], terminal: hash["terminal"])
        end

        class << self
          def label = "Orca"
          def keeps_workspaces? = true
        end

        def unready_reason
          return "no repository set (config \"repo\")" if repo.blank?
          "no runner address set (Settings)" unless Harbor::Runner.configured?
        end

        # Raises unless the server answers and can take work.
        def health_check
          status = client.status
          raise "Orca #{status[:version]} is not ready" unless status[:ready]
          status
        end

        def runner_name = [ runtime.name, environment ].compact_blank.uniq.join(" · ")

        def worktree_name(run) = "harbor-run-#{run.id}"

        # Makes a worktree for the run and starts `command` in a terminal
        # there. Returns at once with the Session; the command reports its own
        # output and result.
        def start(run:, command:, base: nil, title: nil)
          worktree = client.create_worktree(repo:, name: worktree_name(run), base:, setup: runtime.config["setup"].presence || "skip")
          begin
            terminal = client.start_terminal(worktree:, command: Harbor::Runner.command_for(run, command),
                                             title: title || "Run #{run.id}")
          rescue StandardError
            client.remove_worktree(worktree, force: true) rescue nil
            raise
          end
          Session.new(worktree_id: worktree.id, worktree_path: worktree.path, terminal: terminal.handle)
        end

        # Stops the run's command. False when it had already gone.
        def stop(session) = client.close_terminal(session.terminal)

        # Removes the run's worktree, changes and all.
        def cleanup(session, delete_branch: true)
          client.remove_worktree("id:#{session.worktree_id}", force: true, delete_branch:)
        end

        def client = options[:client] || (@client ||= Harbor::Orca::Client.new(environment:))

        private

        def repo = runtime.config["repo"].to_s.strip.presence
        def environment = runtime.config["environment"].to_s.strip.presence
      end
    end
  end
end
