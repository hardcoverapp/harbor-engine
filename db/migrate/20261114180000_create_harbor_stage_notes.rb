# Overview's stage notes: one short hand-written paragraph per stage. A host
# Harbor was extracted from already has the table; there this records itself
# and changes nothing.
class CreateHarborStageNotes < ActiveRecord::Migration[8.1]
  def change
    create_table :factory_notes, if_not_exists: true do |t|
      t.string :stage_key, null: false
      t.text :body, null: false, default: ""
      t.bigint :updated_by_user_id
      t.timestamps
    end
    add_index :factory_notes, :stage_key, unique: true, if_not_exists: true
    add_index :factory_notes, :updated_by_user_id, if_not_exists: true
  end
end
