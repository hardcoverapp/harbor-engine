# Runs and their events. A host Harbor was extracted from already has both
# tables; there this records itself and changes nothing.
class CreateHarborRuns < ActiveRecord::Migration[8.1]
  def change
    create_table :runs, if_not_exists: true do |t|
      # What it is
      t.string :loader
      t.string :skill
      t.string :task_type
      t.string :agent_key
      t.string :acting_as
      t.text :command
      t.string :subject_type
      t.bigint :subject_id
      t.integer :github_issue_number

      # What started it
      t.string :trigger_source, null: false, default: "manual"
      t.string :trigger
      t.string :trigger_ref
      t.bigint :triggered_by_user_id
      t.bigint :automation_id
      t.bigint :workflow_run_id
      t.string :workflow_step_key
      t.bigint :parent_run_id
      t.string :idempotency_key
      t.string :join_key

      # Where and how it ran
      t.string :status, null: false, default: "queued"
      t.string :executor
      t.string :runner_name
      t.bigint :runtime_id
      t.string :model
      t.string :effort
      t.jsonb :model_execution, null: false, default: {}
      t.jsonb :model_wait_job, null: false, default: {}
      t.datetime :model_switch_requested_at
      t.string :session_id
      t.datetime :started_at
      t.datetime :ended_at
      t.bigint :duration_ms

      # What it produced
      t.jsonb :input, null: false, default: {}
      t.jsonb :output, null: false, default: {}
      t.jsonb :progress, null: false, default: {}
      t.text :error
      t.string :error_class
      t.string :raw_log_path
      t.datetime :resolved_at
      t.bigint :resolved_by_user_id

      # What it cost
      t.decimal :cost_usd_actual, precision: 10, scale: 6
      t.decimal :cost_usd_estimate, precision: 10, scale: 6
      t.integer :input_tokens
      t.integer :output_tokens
      t.integer :cache_read_tokens
      t.integer :cache_creation_tokens

      t.timestamps
    end

    add_index :runs, :status, if_not_exists: true
    add_index :runs, :started_at, if_not_exists: true
    add_index :runs, :agent_key, if_not_exists: true
    add_index :runs, %i[loader started_at], if_not_exists: true
    add_index :runs, %i[subject_type subject_id], if_not_exists: true
    add_index :runs, :parent_run_id, where: "parent_run_id IS NOT NULL", if_not_exists: true
    add_index :runs, :idempotency_key, unique: true, where: "idempotency_key IS NOT NULL", if_not_exists: true
    # One live run per join key: whichever trigger arrives first holds it.
    add_index :runs, :join_key, unique: true, name: "index_runs_on_live_join_key", if_not_exists: true,
              where: "join_key IS NOT NULL AND status IN ('queued', 'waiting_for_model', 'running')"

    create_table :run_events, if_not_exists: true do |t|
      t.bigint :run_id, null: false
      t.integer :seq, null: false
      t.string :event_type, null: false
      t.string :subtype
      t.string :tool_name
      t.string :summary
      t.jsonb :payload, null: false, default: {}
      t.datetime :occurred_at, null: false
      t.timestamps
    end

    add_index :run_events, %i[run_id seq], unique: true, if_not_exists: true
    add_foreign_key :run_events, :runs, if_not_exists: true
  end
end
