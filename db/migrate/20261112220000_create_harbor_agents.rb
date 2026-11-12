# Agents, their documents, the text every agent shares, and which agent
# handles which task type. A host Harbor was extracted from already has the
# tables; there this records itself and changes nothing.
class CreateHarborAgents < ActiveRecord::Migration[8.1]
  def change
    create_table :agents, if_not_exists: true do |t|
      t.string :key, null: false
      t.string :name
      t.text :description
      t.boolean :enabled, null: false, default: true
      t.text :system_prompt
      t.bigint :model_alias_id
      t.jsonb :tools, null: false, default: {}
      t.jsonb :configuration, null: false, default: {}
      t.jsonb :default_tasks, null: false, default: []
      t.binary :avatar_data
      t.string :avatar_content_type
      t.timestamps
    end
    add_index :agents, :key, unique: true, if_not_exists: true
    add_index :agents, :model_alias_id, if_not_exists: true
    add_foreign_key :agents, :model_aliases, if_not_exists: true

    create_table :agent_documents, if_not_exists: true do |t|
      t.bigint :agent_id, null: false
      t.string :path, null: false
      t.text :body
      t.timestamps
    end
    add_index :agent_documents, %i[agent_id path], unique: true, if_not_exists: true
    add_index :agent_documents, :agent_id, if_not_exists: true
    add_foreign_key :agent_documents, :agents, if_not_exists: true

    create_table :agent_settings, if_not_exists: true do |t|
      t.string :key, null: false
      t.text :body
      t.timestamps
    end
    add_index :agent_settings, :key, unique: true, if_not_exists: true

    create_table :task_assignments, if_not_exists: true do |t|
      t.string :task_type, null: false
      t.string :agent_key, null: false
      t.timestamps
    end
    add_index :task_assignments, :task_type, unique: true, if_not_exists: true
    add_index :task_assignments, :agent_key, if_not_exists: true
  end
end
