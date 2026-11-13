require "harbor/orca/client"

module Harbor
  # Orca (https://github.com/stablyai/orca) is where Harbor runs agents: it
  # makes the worktree, and a run is a command in an Orca terminal there. An
  # Orca server can be the one beside Harbor or a paired one on another machine.
  module Orca
    class << self
      # What runs the orca command for a client that isn't given a runner of
      # its own: something taking (argv, timeout:) and returning [stdout,
      # stderr, exit status]. nil: the real command. Tests set a stand-in, so
      # code that builds its own client never reaches a real server.
      attr_accessor :runner
    end
  end
end
