# The catalog of database dumps. A host Harbor was extracted from already has
# the table; there this records itself and changes nothing.
class CreateHarborDatabaseBackups < ActiveRecord::Migration[8.1]
  def change
    create_table :database_backups, if_not_exists: true do |t|
      t.string :database_key, null: false
      t.string :variant, null: false
      t.string :path, null: false
      t.bigint :bytes, null: false
      t.string :sha256, null: false
      t.jsonb :copies, null: false, default: {}
      t.bigint :run_id
      t.timestamps
    end

    add_index :database_backups, %i[database_key created_at], if_not_exists: true
    add_index :database_backups, :path, unique: true, if_not_exists: true
    add_index :database_backups, :run_id, if_not_exists: true
    add_foreign_key :database_backups, :runs, if_not_exists: true
  end
end
