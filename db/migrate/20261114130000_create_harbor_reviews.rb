# Review policy: the rules with their versions, the rounds with their checks,
# and what happened afterwards (feedback and escapes). A host Harbor was
# extracted from already has the tables; there this records itself and
# changes nothing.
class CreateHarborReviews < ActiveRecord::Migration[8.1]
  def change
    create_table :review_rules, if_not_exists: true do |t|
      t.string :kind, null: false             # risk | check | signoff
      t.string :key, null: false
      t.string :repo, null: false, default: "*"
      t.string :name, null: false
      t.string :mode, null: false, default: "live" # live | shadow | off
      t.bigint :current_version_id
      t.timestamps
    end
    add_index :review_rules, %i[kind repo key], unique: true, if_not_exists: true

    create_table :review_rule_versions, if_not_exists: true do |t|
      t.bigint :review_rule_id, null: false
      t.integer :number, null: false
      t.jsonb :definition, null: false, default: {}
      t.bigint :created_by_user_id
      t.datetime :created_at, null: false
    end
    add_index :review_rule_versions, :review_rule_id, if_not_exists: true
    add_index :review_rule_versions, %i[review_rule_id number], unique: true, if_not_exists: true
    add_foreign_key :review_rule_versions, :review_rules, if_not_exists: true

    create_table :review_rounds, if_not_exists: true do |t|
      t.string :repo, null: false
      t.integer :pr_number, null: false
      t.string :head_sha, null: false
      t.integer :round, null: false, default: 1
      t.string :phase, null: false, default: "triage"
      t.string :trigger_source, null: false, default: "webhook"
      t.bigint :run_id
      t.bigint :parent_run_id
      t.bigint :workflow_run_id
      t.boolean :dry_run, null: false, default: false
      t.boolean :awaiting_join, null: false, default: false
      t.jsonb :risks, null: false, default: []
      t.jsonb :gaps, null: false, default: []
      t.jsonb :signoffs, null: false, default: []
      t.jsonb :gate, null: false, default: {}
      t.jsonb :review, null: false, default: {}
      t.jsonb :input, null: false, default: {}
      t.jsonb :document, null: false, default: {}
      t.string :patch_id
      t.bigint :github_check_run_id
      t.bigint :github_review_id
      t.string :published_digest
      t.datetime :published_at
      t.string :superseded_by_sha
      t.text :error
      t.datetime :finished_at
      t.timestamps
    end
    add_index :review_rounds, %i[repo pr_number round], if_not_exists: true
    add_index :review_rounds, %i[repo pr_number head_sha], if_not_exists: true
    # At most one unfinished round per pull request.
    add_index :review_rounds, %i[repo pr_number], unique: true, name: "index_review_rounds_one_open_per_pr",
              where: "phase NOT IN ('published','cancelled','failed')", if_not_exists: true

    create_table :review_check_runs, if_not_exists: true do |t|
      t.bigint :review_round_id, null: false
      t.bigint :review_rule_id, null: false
      t.string :check_key, null: false
      t.integer :check_version, null: false
      t.string :stage, null: false, default: "evidence"
      t.string :gate, null: false, default: "blocking"
      t.string :mode, null: false, default: "live"
      t.string :status, null: false, default: "queued"
      t.integer :progress_done
      t.integer :progress_total
      t.string :progress_note
      t.string :summary
      t.jsonb :outputs, null: false, default: {}
      t.jsonb :artifacts, null: false, default: []
      t.jsonb :details, null: false, default: {}
      t.jsonb :routed, null: false, default: []
      t.bigint :run_id
      t.bigint :reused_from_id
      t.string :watch_digest
      t.datetime :started_at
      t.datetime :finished_at
      t.timestamps
    end
    add_index :review_check_runs, :review_round_id, if_not_exists: true
    add_index :review_check_runs, %i[review_round_id check_key], unique: true, if_not_exists: true
    add_index :review_check_runs, %i[check_key status], if_not_exists: true
    add_foreign_key :review_check_runs, :review_rounds, if_not_exists: true

    create_table :review_feedbacks, if_not_exists: true do |t|
      t.bigint :review_round_id, null: false
      t.string :subject_kind, null: false     # finding | check | signoff
      t.string :subject_key, null: false      # finding category / check key / signoff key
      t.string :signal, null: false           # useful | noise | accepted | overridden
      t.string :detail                        # thumbs_up, resolved_with_change, …
      t.string :by
      t.bigint :github_comment_id
      t.datetime :created_at, null: false
    end
    add_index :review_feedbacks, %i[subject_kind subject_key], if_not_exists: true
    add_index :review_feedbacks, %i[github_comment_id detail], unique: true, where: "github_comment_id IS NOT NULL",
              if_not_exists: true

    create_table :review_escapes, if_not_exists: true do |t|
      t.bigint :review_round_id
      t.string :repo, null: false
      t.integer :pr_number, null: false
      t.string :source, null: false           # regressed_in | deploy_errors | bugsnag
      t.string :ref                           # the fix, the error's address…
      t.text :note
      t.text :analysis                        # "which rule would have caught this?"
      t.bigint :analysis_run_id
      t.timestamps
    end
    add_index :review_escapes, %i[repo pr_number], if_not_exists: true
    add_index :review_escapes, %i[source ref], unique: true, if_not_exists: true
  end
end
