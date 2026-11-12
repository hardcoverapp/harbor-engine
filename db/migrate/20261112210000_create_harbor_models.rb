# Model providers, aliases and each alias's ordered choices. A host Harbor was
# extracted from already has the tables; there this records itself and changes
# nothing.
class CreateHarborModels < ActiveRecord::Migration[8.1]
  def change
    create_table :model_providers, if_not_exists: true do |t|
      t.string :key, null: false
      t.boolean :enabled, null: false, default: true
      t.decimal :session_used_percent, precision: 6, scale: 2
      t.datetime :session_resets_at
      t.decimal :weekly_used_percent, precision: 6, scale: 2
      t.datetime :weekly_resets_at
      t.datetime :usage_checked_at
      t.text :usage_error
      t.timestamps
    end
    add_index :model_providers, :key, unique: true, if_not_exists: true

    create_table :model_aliases, if_not_exists: true do |t|
      t.string :name, null: false
      t.text :description
      t.timestamps
    end
    add_index :model_aliases, :name, unique: true, if_not_exists: true

    create_table :model_choices, if_not_exists: true do |t|
      t.bigint :model_alias_id, null: false
      t.bigint :model_provider_id, null: false
      t.string :model, null: false
      t.string :effort
      t.integer :position, null: false, default: 0
      t.integer :cutoff_percent, null: false, default: 80
      t.timestamps
    end
    add_index :model_choices, :model_alias_id, if_not_exists: true
    add_index :model_choices, :model_provider_id, if_not_exists: true
    add_foreign_key :model_choices, :model_aliases, if_not_exists: true
    add_foreign_key :model_choices, :model_providers, if_not_exists: true
  end
end
