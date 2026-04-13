class CreateWallets < ActiveRecord::Migration[7.2]
  def change
    create_table :wallets do |t|
      t.references :agent, null: false, foreign_key: true, index: { unique: true }
      t.decimal :wallet_size, precision: 15, scale: 2, null: false, default: 20000
      t.decimal :cash, precision: 15, scale: 2, null: false, default: 20000
      t.decimal :invested, precision: 15, scale: 2, null: false, default: 0

      t.timestamps
    end
  end
end
