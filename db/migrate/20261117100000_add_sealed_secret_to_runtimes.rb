# A runtime's own secret (an Orca server's pairing code), kept encrypted so
# it can be given on the runtime's page and used without a restart.
class AddSealedSecretToRuntimes < ActiveRecord::Migration[8.1]
  def change
    add_column :runtimes, :sealed_secret, :text, if_not_exists: true
    add_column :runtimes, :secret_set_at, :datetime, if_not_exists: true
  end
end
