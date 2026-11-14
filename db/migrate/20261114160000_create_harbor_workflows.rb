# Workflows, their versions, their runs, each run's step runs and the waits
# steps are parked on. A host Harbor was extracted from already has the tables;
# there this records itself and changes nothing.
class CreateHarborWorkflows < ActiveRecord::Migration[8.1]
  def change
    create_table :workflows, if_not_exists: true do |t|
      t.string :key, null: false
      t.string :name, null: false
      t.text :description
      t.string :mode, null: false, default: "off"
      t.string :claims, null: false, default: [], array: true
      t.bigint :current_version_id
      t.timestamps
    end
    add_index :workflows, :key, unique: true, if_not_exists: true

    create_table :workflow_versions, if_not_exists: true do |t|
      t.bigint :workflow_id, null: false
      t.integer :number, null: false
      t.jsonb :definition, null: false, default: {}
      t.bigint :created_by_user_id
      t.datetime :created_at, null: false
    end
    add_index :workflow_versions, :workflow_id, if_not_exists: true
    add_index :workflow_versions, %i[workflow_id number], unique: true, if_not_exists: true
    add_index :workflow_versions, :created_by_user_id, if_not_exists: true
    add_foreign_key :workflow_versions, :workflows, if_not_exists: true

    create_table :workflow_runs, if_not_exists: true do |t|
      t.bigint :workflow_id, null: false
      t.bigint :workflow_version_id, null: false
      t.string :status, null: false, default: "queued"
      t.string :mode, null: false
      t.string :phase, null: false, default: "main"
      t.string :outcome
      t.text :note
      t.text :error

      # What started it
      t.string :trigger_kind, null: false
      t.bigint :webhook_event_id
      t.bigint :triggered_by_user_id
      t.bigint :parent_workflow_run_id
      t.string :parent_step_key
      t.string :dedupe_key

      # What it is about
      t.string :github_repo
      t.integer :pr_number
      t.integer :issue_number

      t.jsonb :context, null: false, default: {}
      t.datetime :started_at
      t.datetime :ended_at
      t.timestamps
    end
    add_index :workflow_runs, :workflow_id, if_not_exists: true
    add_index :workflow_runs, %i[workflow_id status], if_not_exists: true
    add_index :workflow_runs, :workflow_version_id, if_not_exists: true
    add_index :workflow_runs, :webhook_event_id, if_not_exists: true
    add_index :workflow_runs, :triggered_by_user_id, if_not_exists: true
    add_index :workflow_runs, :parent_workflow_run_id, if_not_exists: true
    add_index :workflow_runs, :dedupe_key, unique: true, where: "(dedupe_key IS NOT NULL)", if_not_exists: true
    add_index :workflow_runs, %i[github_repo pr_number], if_not_exists: true
    add_index :workflow_runs, %i[github_repo issue_number], if_not_exists: true
    add_foreign_key :workflow_runs, :workflows, if_not_exists: true
    add_foreign_key :workflow_runs, :workflow_versions, if_not_exists: true
    add_foreign_key :workflow_runs, :webhook_events, if_not_exists: true
    add_foreign_key :workflow_runs, :workflow_runs, column: :parent_workflow_run_id, if_not_exists: true

    create_table :workflow_step_runs, if_not_exists: true do |t|
      t.bigint :workflow_run_id, null: false
      t.string :step_key, null: false
      t.string :step_type, null: false
      t.string :scope, null: false, default: ""
      t.integer :iteration
      t.string :status, null: false, default: "running"
      t.bigint :run_id
      t.jsonb :input, null: false, default: {}
      t.jsonb :output, null: false, default: {}
      t.text :error
      t.datetime :started_at
      t.datetime :ended_at
      t.timestamps
    end
    add_index :workflow_step_runs, :workflow_run_id, if_not_exists: true
    add_index :workflow_step_runs, %i[workflow_run_id scope step_key], unique: true, if_not_exists: true
    add_index :workflow_step_runs, :run_id, if_not_exists: true
    add_foreign_key :workflow_step_runs, :workflow_runs, if_not_exists: true
    add_foreign_key :workflow_step_runs, :runs, if_not_exists: true

    create_table :workflow_waits, if_not_exists: true do |t|
      t.bigint :workflow_run_id, null: false
      t.bigint :workflow_step_run_id, null: false
      t.string :github_repo
      t.integer :number
      t.jsonb :matcher, null: false, default: {}
      t.datetime :expires_at
      t.timestamps
    end
    add_index :workflow_waits, :workflow_run_id, if_not_exists: true
    add_index :workflow_waits, :workflow_step_run_id, if_not_exists: true
    add_index :workflow_waits, :expires_at, if_not_exists: true
    add_index :workflow_waits, %i[github_repo number], if_not_exists: true
    add_foreign_key :workflow_waits, :workflow_runs, if_not_exists: true
    add_foreign_key :workflow_waits, :workflow_step_runs, if_not_exists: true

    add_index :runs, :workflow_run_id, if_not_exists: true
    add_foreign_key :runs, :workflow_runs, if_not_exists: true
  end
end
