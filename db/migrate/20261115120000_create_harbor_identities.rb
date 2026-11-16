# The accounts agents act as (Harbor::Identity): a name, the account's login
# and the name of the environment variable that holds its token. Never the
# token. An agent picks one (`agents.identity_id`).
class CreateHarborIdentities < ActiveRecord::Migration[8.1]
  def change
    create_table :harbor_identities, if_not_exists: true do |t|
      t.string :name, null: false
      t.string :kind, null: false, default: "github"
      t.string :login, null: false
      t.string :token_env, null: false
      t.timestamps
    end
    add_index :harbor_identities, :name, unique: true, if_not_exists: true
    add_index :harbor_identities, "kind, lower(login)", unique: true, name: "index_harbor_identities_on_kind_and_login", if_not_exists: true

    add_column :agents, :identity_id, :bigint, if_not_exists: true
    add_index :agents, :identity_id, if_not_exists: true
  end
end
