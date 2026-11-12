# Runtimes, workspaces (ordered lists of runtimes), and what ties agents and
# runs to them. A host Harbor was extracted from already has all of it; there
# this records itself and changes nothing.
class CreateHarborRuntimes < ActiveRecord::Migration[8.1]
  def change
    create_table :runtimes, if_not_exists: true do |t|
      t.string :key, null: false
      t.string :name, null: false
      t.string :backend, null: false
      t.string :host
      t.boolean :enabled, null: false, default: true
      t.integer :max_concurrent, null: false, default: 5
      t.integer :position, null: false, default: 0
      t.jsonb :config, null: false, default: {}
      t.datetime :checked_at
      t.text :last_error
      t.timestamps
    end
    add_index :runtimes, :key, unique: true, if_not_exists: true

    create_table :workspace_profiles, if_not_exists: true do |t|
      t.string :key, null: false
      t.string :name, null: false
      t.text :description
      t.timestamps
    end
    add_index :workspace_profiles, :key, unique: true, if_not_exists: true
    add_index :workspace_profiles, :name, unique: true, if_not_exists: true

    create_table :workspace_profile_runtimes, if_not_exists: true do |t|
      t.bigint :workspace_profile_id, null: false
      t.bigint :runtime_id, null: false
      t.integer :position, null: false, default: 0
      t.timestamps
    end
    add_index :workspace_profile_runtimes, %i[workspace_profile_id runtime_id], unique: true,
              name: "index_workspace_profile_runtimes_uniqueness", if_not_exists: true
    add_index :workspace_profile_runtimes, :runtime_id, if_not_exists: true
    add_index :workspace_profile_runtimes, :workspace_profile_id, if_not_exists: true
    add_foreign_key :workspace_profile_runtimes, :runtimes, if_not_exists: true
    add_foreign_key :workspace_profile_runtimes, :workspace_profiles, if_not_exists: true

    add_column :agents, :workspace_profile_id, :bigint, if_not_exists: true
    add_column :agents, :max_agents, :integer, null: false, default: 5, if_not_exists: true
    add_column :agents, :max_workspaces, :integer, null: false, default: 1, if_not_exists: true
    add_index :agents, :workspace_profile_id, if_not_exists: true
    add_foreign_key :agents, :workspace_profiles, if_not_exists: true

    add_column :runs, :runtime_id, :bigint, if_not_exists: true
    add_index :runs, :runtime_id, if_not_exists: true
    add_foreign_key :runs, :runtimes, if_not_exists: true
  end
end
