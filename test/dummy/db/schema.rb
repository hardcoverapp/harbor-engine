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

ActiveRecord::Schema[8.1].define(version: 2026_11_17_100000) do
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
    t.bigint "identity_id"
    t.index ["identity_id"], name: "index_agents_on_identity_id"
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

  create_table "factory_notes", force: :cascade do |t|
    t.string "stage_key", null: false
    t.text "body", default: "", null: false
    t.bigint "updated_by_user_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["stage_key"], name: "index_factory_notes_on_stage_key", unique: true
    t.index ["updated_by_user_id"], name: "index_factory_notes_on_updated_by_user_id"
  end

  create_table "harbor_identities", force: :cascade do |t|
    t.string "name", null: false
    t.string "kind", default: "github", null: false
    t.string "login", null: false
    t.string "token_env", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index "kind, lower((login)::text)", name: "index_harbor_identities_on_kind_and_login", unique: true
    t.index ["name"], name: "index_harbor_identities_on_name", unique: true
  end

  create_table "harbor_machines", force: :cascade do |t|
    t.bigint "run_id", null: false
    t.bigint "runtime_id"
    t.string "recipe", null: false
    t.string "instance_id", null: false
    t.string "status", default: "creating", null: false
    t.text "sealed_result"
    t.jsonb "recipe_snapshot", default: {}, null: false
    t.string "claim"
    t.datetime "create_started_at"
    t.datetime "beat_at"
    t.integer "create_pid"
    t.string "create_pid_mark"
    t.string "create_host"
    t.datetime "ready_at"
    t.datetime "released_at"
    t.datetime "destroying_at"
    t.datetime "destroy_tried_at"
    t.integer "destroy_attempts", default: 0, null: false
    t.text "destroy_error"
    t.datetime "destroyed_at"
    t.string "note"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["instance_id"], name: "index_harbor_machines_on_instance_id", unique: true
    t.index ["run_id"], name: "index_harbor_machines_on_run_id", unique: true
    t.index ["runtime_id"], name: "index_harbor_machines_on_runtime_id"
    t.index ["status"], name: "index_harbor_machines_on_status"
  end

  create_table "harbor_settings", force: :cascade do |t|
    t.string "key", null: false
    t.jsonb "value"
    t.string "updated_by"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["key"], name: "index_harbor_settings_on_key", unique: true
  end

  create_table "improvement_proposals", force: :cascade do |t|
    t.bigint "scorer_id"
    t.string "agent_key", null: false
    t.bigint "run_id"
    t.string "target_kind", null: false
    t.string "document_path"
    t.string "status", default: "proposed", null: false
    t.text "summary", null: false
    t.text "before"
    t.text "after"
    t.text "regressions_addressed"
    t.jsonb "evidence", default: {}, null: false
    t.bigint "pr_run_id"
    t.string "pr_url"
    t.bigint "applied_by_user_id"
    t.datetime "applied_at"
    t.datetime "dismissed_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["agent_key"], name: "index_improvement_proposals_on_agent_key"
    t.index ["applied_by_user_id"], name: "index_improvement_proposals_on_applied_by_user_id"
    t.index ["pr_run_id"], name: "index_improvement_proposals_on_pr_run_id"
    t.index ["run_id"], name: "index_improvement_proposals_on_run_id"
    t.index ["scorer_id"], name: "index_improvement_proposals_on_scorer_id"
    t.index ["status"], name: "index_improvement_proposals_on_status"
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

  create_table "review_check_runs", force: :cascade do |t|
    t.bigint "review_round_id", null: false
    t.bigint "review_rule_id", null: false
    t.string "check_key", null: false
    t.integer "check_version", null: false
    t.string "stage", default: "evidence", null: false
    t.string "gate", default: "blocking", null: false
    t.string "mode", default: "live", null: false
    t.string "status", default: "queued", null: false
    t.integer "progress_done"
    t.integer "progress_total"
    t.string "progress_note"
    t.string "summary"
    t.jsonb "outputs", default: {}, null: false
    t.jsonb "artifacts", default: [], null: false
    t.jsonb "details", default: {}, null: false
    t.jsonb "routed", default: [], null: false
    t.bigint "run_id"
    t.bigint "reused_from_id"
    t.string "watch_digest"
    t.datetime "started_at"
    t.datetime "finished_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["check_key", "status"], name: "index_review_check_runs_on_check_key_and_status"
    t.index ["review_round_id", "check_key"], name: "index_review_check_runs_on_review_round_id_and_check_key", unique: true
    t.index ["review_round_id"], name: "index_review_check_runs_on_review_round_id"
  end

  create_table "review_escapes", force: :cascade do |t|
    t.bigint "review_round_id"
    t.string "repo", null: false
    t.integer "pr_number", null: false
    t.string "source", null: false
    t.string "ref"
    t.text "note"
    t.text "analysis"
    t.bigint "analysis_run_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["repo", "pr_number"], name: "index_review_escapes_on_repo_and_pr_number"
    t.index ["source", "ref"], name: "index_review_escapes_on_source_and_ref", unique: true
  end

  create_table "review_feedbacks", force: :cascade do |t|
    t.bigint "review_round_id", null: false
    t.string "subject_kind", null: false
    t.string "subject_key", null: false
    t.string "signal", null: false
    t.string "detail"
    t.string "by"
    t.bigint "github_comment_id"
    t.datetime "created_at", null: false
    t.index ["github_comment_id", "detail"], name: "index_review_feedbacks_on_github_comment_id_and_detail", unique: true, where: "(github_comment_id IS NOT NULL)"
    t.index ["subject_kind", "subject_key"], name: "index_review_feedbacks_on_subject_kind_and_subject_key"
  end

  create_table "review_rounds", force: :cascade do |t|
    t.string "repo", null: false
    t.integer "pr_number", null: false
    t.string "head_sha", null: false
    t.integer "round", default: 1, null: false
    t.string "phase", default: "triage", null: false
    t.string "trigger_source", default: "webhook", null: false
    t.bigint "run_id"
    t.bigint "parent_run_id"
    t.bigint "workflow_run_id"
    t.boolean "dry_run", default: false, null: false
    t.boolean "awaiting_join", default: false, null: false
    t.jsonb "risks", default: [], null: false
    t.jsonb "gaps", default: [], null: false
    t.jsonb "signoffs", default: [], null: false
    t.jsonb "gate", default: {}, null: false
    t.jsonb "review", default: {}, null: false
    t.jsonb "input", default: {}, null: false
    t.jsonb "document", default: {}, null: false
    t.string "patch_id"
    t.bigint "github_check_run_id"
    t.bigint "github_review_id"
    t.string "published_digest"
    t.datetime "published_at"
    t.string "superseded_by_sha"
    t.text "error"
    t.datetime "finished_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["repo", "pr_number", "head_sha"], name: "index_review_rounds_on_repo_and_pr_number_and_head_sha"
    t.index ["repo", "pr_number", "round"], name: "index_review_rounds_on_repo_and_pr_number_and_round"
    t.index ["repo", "pr_number"], name: "index_review_rounds_one_open_per_pr", unique: true, where: "((phase)::text <> ALL (ARRAY[('published'::character varying)::text, ('cancelled'::character varying)::text, ('failed'::character varying)::text]))"
  end

  create_table "review_rule_versions", force: :cascade do |t|
    t.bigint "review_rule_id", null: false
    t.integer "number", null: false
    t.jsonb "definition", default: {}, null: false
    t.bigint "created_by_user_id"
    t.datetime "created_at", null: false
    t.index ["review_rule_id", "number"], name: "index_review_rule_versions_on_review_rule_id_and_number", unique: true
    t.index ["review_rule_id"], name: "index_review_rule_versions_on_review_rule_id"
  end

  create_table "review_rules", force: :cascade do |t|
    t.string "kind", null: false
    t.string "key", null: false
    t.string "repo", default: "*", null: false
    t.string "name", null: false
    t.string "mode", default: "live", null: false
    t.bigint "current_version_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["kind", "repo", "key"], name: "index_review_rules_on_kind_and_repo_and_key", unique: true
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
    t.text "sealed_secret"
    t.datetime "secret_set_at"
    t.index ["key"], name: "index_runtimes_on_key", unique: true
  end

  create_table "scorer_results", force: :cascade do |t|
    t.bigint "scorer_id", null: false
    t.bigint "run_id", null: false
    t.bigint "judge_run_id"
    t.string "status", default: "queued", null: false
    t.string "classification"
    t.decimal "score", precision: 4, scale: 3
    t.boolean "passed"
    t.text "reasoning"
    t.text "error"
    t.datetime "scored_at"
    t.bigint "proposal_id"
    t.datetime "reviewed_at"
    t.datetime "claimed_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["judge_run_id"], name: "index_scorer_results_on_judge_run_id"
    t.index ["proposal_id"], name: "index_scorer_results_on_proposal_id"
    t.index ["run_id"], name: "index_scorer_results_on_run_id"
    t.index ["scorer_id", "run_id"], name: "index_scorer_results_on_scorer_id_and_run_id", unique: true
    t.index ["scorer_id", "scored_at"], name: "index_scorer_results_on_scorer_id_and_scored_at"
    t.index ["scorer_id"], name: "index_scorer_results_on_scorer_id"
  end

  create_table "scorers", force: :cascade do |t|
    t.string "name", null: false
    t.text "description"
    t.text "judge_instructions", null: false
    t.bigint "model_alias_id", null: false
    t.jsonb "classifications", default: [], null: false
    t.decimal "pass_threshold", precision: 4, scale: 3, default: "0.7", null: false
    t.integer "sample_rate", default: 25, null: false
    t.jsonb "agent_keys", default: [], null: false
    t.jsonb "task_types", default: [], null: false
    t.boolean "enabled", default: true, null: false
    t.integer "position", default: 0, null: false
    t.boolean "self_improvement", default: false, null: false
    t.integer "improvement_min_failures", default: 25, null: false
    t.integer "improvement_max_age_days", default: 7, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["model_alias_id"], name: "index_scorers_on_model_alias_id"
    t.index ["name"], name: "index_scorers_on_name", unique: true
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
  add_foreign_key "improvement_proposals", "runs"
  add_foreign_key "improvement_proposals", "runs", column: "pr_run_id", on_delete: :nullify
  add_foreign_key "improvement_proposals", "scorers", on_delete: :nullify
  add_foreign_key "model_choices", "model_aliases"
  add_foreign_key "model_choices", "model_providers"
  add_foreign_key "review_check_runs", "review_rounds"
  add_foreign_key "review_rule_versions", "review_rules"
  add_foreign_key "run_events", "runs"
  add_foreign_key "runs", "automations", on_delete: :nullify
  add_foreign_key "runs", "runtimes"
  add_foreign_key "runs", "workflow_runs"
  add_foreign_key "scorer_results", "improvement_proposals", column: "proposal_id", on_delete: :nullify
  add_foreign_key "scorer_results", "runs"
  add_foreign_key "scorer_results", "runs", column: "judge_run_id", on_delete: :nullify
  add_foreign_key "scorer_results", "scorers"
  add_foreign_key "scorers", "model_aliases"
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
