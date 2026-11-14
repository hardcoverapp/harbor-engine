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

ActiveRecord::Schema[8.1].define(version: 2026_11_14_160000) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "agent_documents", force: :cascade do |t|
    t.bigint "agent_id", null: false
    t.string "path", null: false
    t.text "body"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["agent_id", "path"], name: "index_agent_documents_on_agent_id_and_path", unique: true
    t.index ["agent_id"], name: "index_agent_documents_on_agent_id"
  end

  create_table "agent_settings", force: :cascade do |t|
    t.string "key", null: false
    t.text "body"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["key"], name: "index_agent_settings_on_key", unique: true
  end

  create_table "agents", force: :cascade do |t|
    t.string "key", null: false
    t.string "name"
    t.text "description"
    t.boolean "enabled", default: true, null: false
    t.text "system_prompt"
    t.bigint "model_alias_id"
    t.jsonb "tools", default: {}, null: false
    t.jsonb "configuration", default: {}, null: false
    t.jsonb "default_tasks", default: [], null: false
    t.binary "avatar_data"
    t.string "avatar_content_type"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "workspace_profile_id"
    t.integer "max_agents", default: 5, null: false
    t.integer "max_workspaces", default: 1, null: false
    t.index ["key"], name: "index_agents_on_key", unique: true
    t.index ["model_alias_id"], name: "index_agents_on_model_alias_id"
    t.index ["workspace_profile_id"], name: "index_agents_on_workspace_profile_id"
  end

  create_table "automations", force: :cascade do |t|
    t.string "key", null: false
    t.string "name", null: false
    t.text "description"
    t.string "kind", default: "agent", null: false
    t.string "category"
    t.integer "position", default: 0, null: false
    t.boolean "enabled", default: true, null: false
    t.boolean "allow_concurrent", default: false, null: false
    t.string "trigger_kind", default: "manual", null: false
    t.string "cron"
    t.datetime "last_scheduled_at"
    t.string "agent_key"
    t.text "prompt"
    t.string "slash_command"
    t.integer "timeout_ms", default: 900000, null: false
    t.string "cwd_key"
    t.string "run_as"
    t.string "job_class"
    t.string "job_dispatch", default: "loader", null: false
    t.jsonb "job_input", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["enabled", "trigger_kind"], name: "index_automations_on_enabled_and_trigger_kind"
    t.index ["key"], name: "index_automations_on_key", unique: true
  end

  create_table "database_backups", force: :cascade do |t|
    t.string "database_key", null: false
    t.string "variant", null: false
    t.string "path", null: false
    t.bigint "bytes", null: false
    t.string "sha256", null: false
    t.jsonb "copies", default: {}, null: false
    t.bigint "run_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["database_key", "created_at"], name: "index_database_backups_on_database_key_and_created_at"
    t.index ["path"], name: "index_database_backups_on_path", unique: true
    t.index ["run_id"], name: "index_database_backups_on_run_id"
  end

  create_table "harbor_settings", force: :cascade do |t|
    t.string "key", null: false
    t.jsonb "value"
    t.string "updated_by"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["key"], name: "index_harbor_settings_on_key", unique: true
  end

  create_table "model_aliases", force: :cascade do |t|
    t.string "name", null: false
    t.text "description"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["name"], name: "index_model_aliases_on_name", unique: true
  end

  create_table "model_choices", force: :cascade do |t|
    t.bigint "model_alias_id", null: false
    t.bigint "model_provider_id", null: false
    t.string "model", null: false
    t.string "effort"
    t.integer "position", default: 0, null: false
    t.integer "cutoff_percent", default: 80, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["model_alias_id"], name: "index_model_choices_on_model_alias_id"
    t.index ["model_provider_id"], name: "index_model_choices_on_model_provider_id"
  end

  create_table "model_providers", force: :cascade do |t|
    t.string "key", null: false
    t.boolean "enabled", default: true, null: false
    t.decimal "session_used_percent", precision: 6, scale: 2
    t.datetime "session_resets_at"
    t.decimal "weekly_used_percent", precision: 6, scale: 2
    t.datetime "weekly_resets_at"
    t.datetime "usage_checked_at"
    t.text "usage_error"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["key"], name: "index_model_providers_on_key", unique: true
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
    t.jsonb "runner_state", default: {}, null: false
    t.index ["agent_key"], name: "index_runs_on_agent_key"
    t.index ["automation_id"], name: "index_runs_on_automation_id"
    t.index ["idempotency_key"], name: "index_runs_on_idempotency_key", unique: true, where: "(idempotency_key IS NOT NULL)"
    t.index ["join_key"], name: "index_runs_on_live_join_key", unique: true, where: "((join_key IS NOT NULL) AND ((status)::text = ANY (ARRAY[('queued'::character varying)::text, ('waiting_for_model'::character varying)::text, ('running'::character varying)::text])))"
    t.index ["loader", "started_at"], name: "index_runs_on_loader_and_started_at"
    t.index ["parent_run_id"], name: "index_runs_on_parent_run_id", where: "(parent_run_id IS NOT NULL)"
    t.index ["runtime_id"], name: "index_runs_on_runtime_id"
    t.index ["started_at"], name: "index_runs_on_started_at"
    t.index ["status"], name: "index_runs_on_status"
    t.index ["subject_type", "subject_id"], name: "index_runs_on_subject_type_and_subject_id"
    t.index ["workflow_run_id"], name: "index_runs_on_workflow_run_id"
  end

  create_table "runtimes", force: :cascade do |t|
    t.string "key", null: false
    t.string "name", null: false
    t.string "backend", null: false
    t.string "host"
    t.boolean "enabled", default: true, null: false
    t.integer "max_concurrent", default: 5, null: false
    t.integer "position", default: 0, null: false
    t.jsonb "config", default: {}, null: false
    t.datetime "checked_at"
    t.text "last_error"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["key"], name: "index_runtimes_on_key", unique: true
  end

  create_table "task_assignments", force: :cascade do |t|
    t.string "task_type", null: false
    t.string "agent_key", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["agent_key"], name: "index_task_assignments_on_agent_key"
    t.index ["task_type"], name: "index_task_assignments_on_task_type", unique: true
  end

  create_table "webhook_events", force: :cascade do |t|
    t.string "provider", null: false
    t.string "event", null: false
    t.string "action"
    t.string "delivery_id"
    t.string "status", default: "received", null: false
    t.string "matched_handler"
    t.text "note"
    t.jsonb "payload", default: {}, null: false
    t.bigint "run_id"
    t.datetime "received_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["delivery_id"], name: "index_webhook_events_on_delivery_id", unique: true
    t.index ["provider", "received_at"], name: "index_webhook_events_on_provider_and_received_at"
    t.index ["run_id"], name: "index_webhook_events_on_run_id"
    t.index ["status"], name: "index_webhook_events_on_status"
  end

  create_table "workflow_runs", force: :cascade do |t|
    t.bigint "workflow_id", null: false
    t.bigint "workflow_version_id", null: false
    t.string "status", default: "queued", null: false
    t.string "mode", null: false
    t.string "phase", default: "main", null: false
    t.string "outcome"
    t.text "note"
    t.text "error"
    t.string "trigger_kind", null: false
    t.bigint "webhook_event_id"
    t.bigint "triggered_by_user_id"
    t.bigint "parent_workflow_run_id"
    t.string "parent_step_key"
    t.string "dedupe_key"
    t.string "github_repo"
    t.integer "pr_number"
    t.integer "issue_number"
    t.jsonb "context", default: {}, null: false
    t.datetime "started_at"
    t.datetime "ended_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["dedupe_key"], name: "index_workflow_runs_on_dedupe_key", unique: true, where: "(dedupe_key IS NOT NULL)"
    t.index ["github_repo", "issue_number"], name: "index_workflow_runs_on_github_repo_and_issue_number"
    t.index ["github_repo", "pr_number"], name: "index_workflow_runs_on_github_repo_and_pr_number"
    t.index ["parent_workflow_run_id"], name: "index_workflow_runs_on_parent_workflow_run_id"
    t.index ["triggered_by_user_id"], name: "index_workflow_runs_on_triggered_by_user_id"
    t.index ["webhook_event_id"], name: "index_workflow_runs_on_webhook_event_id"
    t.index ["workflow_id", "status"], name: "index_workflow_runs_on_workflow_id_and_status"
    t.index ["workflow_id"], name: "index_workflow_runs_on_workflow_id"
    t.index ["workflow_version_id"], name: "index_workflow_runs_on_workflow_version_id"
  end

  create_table "workflow_step_runs", force: :cascade do |t|
    t.bigint "workflow_run_id", null: false
    t.string "step_key", null: false
    t.string "step_type", null: false
    t.string "scope", default: "", null: false
    t.integer "iteration"
    t.string "status", default: "running", null: false
    t.bigint "run_id"
    t.jsonb "input", default: {}, null: false
    t.jsonb "output", default: {}, null: false
    t.text "error"
    t.datetime "started_at"
    t.datetime "ended_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["run_id"], name: "index_workflow_step_runs_on_run_id"
    t.index ["workflow_run_id", "scope", "step_key"], name: "idx_on_workflow_run_id_scope_step_key_62657d4f8f", unique: true
    t.index ["workflow_run_id"], name: "index_workflow_step_runs_on_workflow_run_id"
  end

  create_table "workflow_versions", force: :cascade do |t|
    t.bigint "workflow_id", null: false
    t.integer "number", null: false
    t.jsonb "definition", default: {}, null: false
    t.bigint "created_by_user_id"
    t.datetime "created_at", null: false
    t.index ["created_by_user_id"], name: "index_workflow_versions_on_created_by_user_id"
    t.index ["workflow_id", "number"], name: "index_workflow_versions_on_workflow_id_and_number", unique: true
    t.index ["workflow_id"], name: "index_workflow_versions_on_workflow_id"
  end

  create_table "workflow_waits", force: :cascade do |t|
    t.bigint "workflow_run_id", null: false
    t.bigint "workflow_step_run_id", null: false
    t.string "github_repo"
    t.integer "number"
    t.jsonb "matcher", default: {}, null: false
    t.datetime "expires_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["expires_at"], name: "index_workflow_waits_on_expires_at"
    t.index ["github_repo", "number"], name: "index_workflow_waits_on_github_repo_and_number"
    t.index ["workflow_run_id"], name: "index_workflow_waits_on_workflow_run_id"
    t.index ["workflow_step_run_id"], name: "index_workflow_waits_on_workflow_step_run_id"
  end

  create_table "workflows", force: :cascade do |t|
    t.string "key", null: false
    t.string "name", null: false
    t.text "description"
    t.string "mode", default: "off", null: false
    t.string "claims", default: [], null: false, array: true
    t.bigint "current_version_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["key"], name: "index_workflows_on_key", unique: true
  end

  create_table "workspace_profile_runtimes", force: :cascade do |t|
    t.bigint "workspace_profile_id", null: false
    t.bigint "runtime_id", null: false
    t.integer "position", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["runtime_id"], name: "index_workspace_profile_runtimes_on_runtime_id"
    t.index ["workspace_profile_id", "runtime_id"], name: "index_workspace_profile_runtimes_uniqueness", unique: true
    t.index ["workspace_profile_id"], name: "index_workspace_profile_runtimes_on_workspace_profile_id"
  end

  create_table "workspace_profiles", force: :cascade do |t|
    t.string "key", null: false
    t.string "name", null: false
    t.text "description"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["key"], name: "index_workspace_profiles_on_key", unique: true
    t.index ["name"], name: "index_workspace_profiles_on_name", unique: true
  end

  add_foreign_key "agent_documents", "agents"
  add_foreign_key "agents", "model_aliases"
  add_foreign_key "agents", "workspace_profiles"
  add_foreign_key "database_backups", "runs"
  add_foreign_key "model_choices", "model_aliases"
  add_foreign_key "model_choices", "model_providers"
  add_foreign_key "run_events", "runs"
  add_foreign_key "runs", "automations", on_delete: :nullify
  add_foreign_key "runs", "runtimes"
  add_foreign_key "runs", "workflow_runs"
  add_foreign_key "webhook_events", "runs"
  add_foreign_key "workflow_runs", "webhook_events"
  add_foreign_key "workflow_runs", "workflow_runs", column: "parent_workflow_run_id"
  add_foreign_key "workflow_runs", "workflow_versions"
  add_foreign_key "workflow_runs", "workflows"
  add_foreign_key "workflow_step_runs", "runs"
  add_foreign_key "workflow_step_runs", "workflow_runs"
  add_foreign_key "workflow_versions", "workflows"
  add_foreign_key "workflow_waits", "workflow_runs"
  add_foreign_key "workflow_waits", "workflow_step_runs"
  add_foreign_key "workspace_profile_runtimes", "runtimes"
  add_foreign_key "workspace_profile_runtimes", "workspace_profiles"
end
