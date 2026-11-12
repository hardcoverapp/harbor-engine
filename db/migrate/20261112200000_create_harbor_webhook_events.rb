# Inbound webhook deliveries. A host Harbor was extracted from already has the
# table; there this records itself and changes nothing.
class CreateHarborWebhookEvents < ActiveRecord::Migration[8.1]
  def change
    create_table :webhook_events, if_not_exists: true do |t|
      t.string :provider, null: false
      t.string :event, null: false
      t.string :action
      t.string :delivery_id
      t.string :status, null: false, default: "received"
      t.string :matched_handler
      t.text :note
      t.jsonb :payload, null: false, default: {}
      t.bigint :run_id
      t.datetime :received_at, null: false
      t.timestamps
    end

    add_index :webhook_events, :delivery_id, unique: true, if_not_exists: true
    add_index :webhook_events, %i[provider received_at], if_not_exists: true
    add_index :webhook_events, :run_id, if_not_exists: true
    add_index :webhook_events, :status, if_not_exists: true
    add_foreign_key :webhook_events, :runs, if_not_exists: true
  end
end
