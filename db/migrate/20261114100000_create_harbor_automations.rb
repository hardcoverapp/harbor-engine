# Automations: what a site does on its own, each row an agent or one of the
# site's jobs with what starts it. A host Harbor was extracted from already
# has the table; there this records itself and changes nothing.
class CreateHarborAutomations < ActiveRecord::Migration[8.1]
  def change
    create_table :automations, if_not_exists: true do |t|
      # What it is
      t.string :key, null: false
      t.string :name, null: false
      t.text :description
      t.string :kind, null: false, default: "agent"
      t.string :category
      t.integer :position, null: false, default: 0
      t.boolean :enabled, null: false, default: true
      t.boolean :allow_concurrent, null: false, default: false

      # What starts it
      t.string :trigger_kind, null: false, default: "manual"
      t.string :cron
      t.datetime :last_scheduled_at

      # An agent automation
      t.string :agent_key
      t.text :prompt
      t.string :slash_command
      t.integer :timeout_ms, null: false, default: 900_000
      t.string :cwd_key
      t.string :run_as

      # A job automation
      t.string :job_class
      t.string :job_dispatch, null: false, default: "loader"
      t.jsonb :job_input, null: false, default: {}

      t.timestamps
    end
    add_index :automations, :key, unique: true, if_not_exists: true
    add_index :automations, %i[enabled trigger_kind], if_not_exists: true

    # A run remembers the automation it fired for; deleting the automation
    # keeps its runs.
    add_index :runs, :automation_id, if_not_exists: true
    add_foreign_key :runs, :automations, on_delete: :nullify, if_not_exists: true
  end
end
