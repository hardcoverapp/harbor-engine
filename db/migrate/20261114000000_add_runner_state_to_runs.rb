# What Harbor keeps about a run's runner while it works: how much of its
# output has arrived and been read, the terminal it runs in, when it was last
# heard from. One column, so the counters change together.
class AddRunnerStateToRuns < ActiveRecord::Migration[8.1]
  def change
    add_column :runs, :runner_state, :jsonb, null: false, default: {}, if_not_exists: true
  end
end
