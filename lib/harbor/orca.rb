require "harbor/orca/client"

module Harbor
  # Orca (https://github.com/stablyai/orca) is where Harbor runs agents: it
  # makes the worktree, and a run is a command in an Orca terminal there. An
  # Orca server can be the one beside Harbor or a paired one on another machine.
  module Orca
  end
end
