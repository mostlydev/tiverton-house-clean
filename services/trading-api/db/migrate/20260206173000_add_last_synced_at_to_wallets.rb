class AddLastSyncedAtToWallets < ActiveRecord::Migration[7.2]
  def change
    add_column :wallets, :last_synced_at, :datetime
    add_index :wallets, :last_synced_at
  end
end
