# Values saved on the Settings page. A row exists only for a setting someone
# has saved; the rest read their ENV fallback or declared default.
class CreateHarborSettings < ActiveRecord::Migration[8.1]
  def change
    create_table :harbor_settings do |t|
      t.string :key, null: false
      t.jsonb :value
      t.string :updated_by
      t.timestamps
    end
    add_index :harbor_settings, :key, unique: true
  end
end
