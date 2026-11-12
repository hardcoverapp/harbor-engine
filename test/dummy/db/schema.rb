# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_11_12_190000) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "harbor_settings", force: :cascade do |t|
    t.string "key", null: false
    t.jsonb "value"
    t.string "updated_by"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["key"], name: "index_harbor_settings_on_key", unique: true
  end

  create_table "run_events", force: :cascade do |t|
    t.bigint "run_id", null: false
    t.integer "seq", null: false
    t.string "event_type", null: false
    t.string "subtype"
    t.string "tool_name"
    t.string "summary"
    t.jsonb "payload", default: {}, null: false
    t.datetime "occurred_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["run_id", "seq"], name: "index_run_events_on_run_id_and_seq", unique: true
  end

  create_table "runs", force: :cascade do |t|
    t.string "loader"
    t.string "skill"
    t.string "task_type"
    t.string "agent_key"
    t.string "acting_as"
    t.text "command"
    t.string "subject_type"
    t.bigint "subject_id"
    t.integer "github_issue_number"
    t.string "trigger_source", default: "manual", null: false
    t.string "trigger"
    t.string "trigger_ref"
    t.bigint "triggered_by_user_id"
    t.bigint "automation_id"
    t.bigint "workflow_run_id"
    t.string "workflow_step_key"
    t.bigint "parent_run_id"
    t.string "idempotency_key"
    t.string "join_key"
    t.string "status", default: "queued", null: false
    t.string "executor"
    t.string "runner_name"
    t.bigint "runtime_id"
    t.string "model"
    t.string "effort"
    t.jsonb "model_execution", default: {}, null: false
    t.jsonb "model_wait_job", default: {}, null: false
    t.datetime "model_switch_requested_at"
    t.string "session_id"
    t.datetime "started_at"
    t.datetime "ended_at"
    t.bigint "duration_ms"
    t.jsonb "input", default: {}, null: false
    t.jsonb "output", default: {}, null: false
    t.jsonb "progress", default: {}, null: false
    t.text "error"
    t.string "error_class"
    t.string "raw_log_path"
    t.datetime "resolved_at"
    t.bigint "resolved_by_user_id"
    t.decimal "cost_usd_actual", precision: 10, scale: 6
    t.decimal "cost_usd_estimate", precision: 10, scale: 6
    t.integer "input_tokens"
    t.integer "output_tokens"
    t.integer "cache_read_tokens"
    t.integer "cache_creation_tokens"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["agent_key"], name: "index_runs_on_agent_key"
    t.index ["idempotency_key"], name: "index_runs_on_idempotency_key", unique: true, where: "(idempotency_key IS NOT NULL)"
    t.index ["join_key"], name: "index_runs_on_live_join_key", unique: true, where: "((join_key IS NOT NULL) AND ((status)::text = ANY ((ARRAY['queued'::character varying, 'waiting_for_model'::character varying, 'running'::character varying])::text[])))"
    t.index ["loader", "started_at"], name: "index_runs_on_loader_and_started_at"
    t.index ["parent_run_id"], name: "index_runs_on_parent_run_id", where: "(parent_run_id IS NOT NULL)"
    t.index ["started_at"], name: "index_runs_on_started_at"
    t.index ["status"], name: "index_runs_on_status"
    t.index ["subject_type", "subject_id"], name: "index_runs_on_subject_type_and_subject_id"
  end

  add_foreign_key "run_events", "runs"
end
