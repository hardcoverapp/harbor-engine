# The machines made for single runs (Harbor::Machine): one row for each run
# placed on an "Orca (per workspace)" runtime, kept after the run so a machine
# that could not be removed is never forgotten.
class CreateHarborMachines < ActiveRecord::Migration[8.1]
  def change
    create_table :harbor_machines do |t|
      t.bigint :run_id, null: false
      t.bigint :runtime_id
      t.string :recipe, null: false
      t.string :instance_id, null: false
      t.string :status, null: false, default: "creating"
      # What `create` printed, pairing code and all, encrypted. Emptied when
      # the machine is removed.
      t.text :sealed_result
      # The recipe's destroy step as it was when the machine was made, for a
      # machine that outlives its recipe's declaration.
      t.jsonb :recipe_snapshot, null: false, default: {}
      t.string :claim
      t.datetime :create_started_at
      t.datetime :beat_at
      t.integer :create_pid
      t.string :create_pid_mark
      t.string :create_host
      t.datetime :ready_at
      t.datetime :released_at
      t.datetime :destroying_at
      t.datetime :destroy_tried_at
      t.integer :destroy_attempts, null: false, default: 0
      t.text :destroy_error
      t.datetime :destroyed_at
      t.string :note
      t.timestamps
    end
    add_index :harbor_machines, :run_id, unique: true
    add_index :harbor_machines, :instance_id, unique: true
    add_index :harbor_machines, :status
    add_index :harbor_machines, :runtime_id
  end
end
