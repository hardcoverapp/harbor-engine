# Scorers, their verdicts on runs, and the proposals drafted from repeated
# failures. A host Harbor was extracted from already has the tables; there
# this records itself and changes nothing.
class CreateHarborScorers < ActiveRecord::Migration[8.1]
  def change
    create_table :scorers, if_not_exists: true do |t|
      t.string :name, null: false
      t.text :description
      t.text :judge_instructions, null: false
      t.bigint :model_alias_id, null: false
      t.jsonb :classifications, null: false, default: []
      t.decimal :pass_threshold, precision: 4, scale: 3, null: false, default: "0.7"
      t.integer :sample_rate, null: false, default: 25
      t.jsonb :agent_keys, null: false, default: []
      t.jsonb :task_types, null: false, default: []
      t.boolean :enabled, null: false, default: true
      t.integer :position, null: false, default: 0
      t.boolean :self_improvement, null: false, default: false
      t.integer :improvement_min_failures, null: false, default: 25
      t.integer :improvement_max_age_days, null: false, default: 7
      t.timestamps
    end
    add_index :scorers, :name, unique: true, if_not_exists: true
    add_index :scorers, :model_alias_id, if_not_exists: true
    add_foreign_key :scorers, :model_aliases, if_not_exists: true

    # `pr_run_id` and `pr_url` are for a host that opens a pull request from
    # a proposal; `applied_by_user_id` is the host's user who applied one.
    create_table :improvement_proposals, if_not_exists: true do |t|
      t.bigint :scorer_id
      t.string :agent_key, null: false
      t.bigint :run_id
      t.string :target_kind, null: false
      t.string :document_path
      t.string :status, null: false, default: "proposed"
      t.text :summary, null: false
      t.text :before
      t.text :after
      t.text :regressions_addressed
      t.jsonb :evidence, null: false, default: {}
      t.bigint :pr_run_id
      t.string :pr_url
      t.bigint :applied_by_user_id
      t.datetime :applied_at
      t.datetime :dismissed_at
      t.timestamps
    end
    add_index :improvement_proposals, :agent_key, if_not_exists: true
    add_index :improvement_proposals, :applied_by_user_id, if_not_exists: true
    add_index :improvement_proposals, :pr_run_id, if_not_exists: true
    add_index :improvement_proposals, :run_id, if_not_exists: true
    add_index :improvement_proposals, :scorer_id, if_not_exists: true
    add_index :improvement_proposals, :status, if_not_exists: true
    add_foreign_key :improvement_proposals, :runs, if_not_exists: true
    add_foreign_key :improvement_proposals, :runs, column: :pr_run_id, on_delete: :nullify, if_not_exists: true
    add_foreign_key :improvement_proposals, :scorers, on_delete: :nullify, if_not_exists: true

    create_table :scorer_results, if_not_exists: true do |t|
      t.bigint :scorer_id, null: false
      t.bigint :run_id, null: false
      t.bigint :judge_run_id
      t.string :status, null: false, default: "queued"
      t.string :classification
      t.decimal :score, precision: 4, scale: 3
      t.boolean :passed
      t.text :reasoning
      t.text :error
      t.datetime :scored_at
      t.bigint :proposal_id
      t.datetime :reviewed_at
      t.datetime :claimed_at
      t.timestamps
    end
    add_index :scorer_results, %i[scorer_id run_id], unique: true, if_not_exists: true
    add_index :scorer_results, %i[scorer_id scored_at], if_not_exists: true
    add_index :scorer_results, :scorer_id, if_not_exists: true
    add_index :scorer_results, :run_id, if_not_exists: true
    add_index :scorer_results, :judge_run_id, if_not_exists: true
    add_index :scorer_results, :proposal_id, if_not_exists: true
    add_foreign_key :scorer_results, :scorers, if_not_exists: true
    add_foreign_key :scorer_results, :runs, if_not_exists: true
    add_foreign_key :scorer_results, :runs, column: :judge_run_id, on_delete: :nullify, if_not_exists: true
    add_foreign_key :scorer_results, :improvement_proposals, column: :proposal_id, on_delete: :nullify, if_not_exists: true
  end
end
