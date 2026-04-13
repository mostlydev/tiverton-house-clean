# frozen_string_literal: true

class CreateBrokerAccountSnapshots < ActiveRecord::Migration[7.2]
  def change
    create_table :broker_account_snapshots do |t|
      t.string :broker, null: false, default: 'alpaca'
      t.decimal :cash, precision: 18, scale: 2
      t.decimal :buying_power, precision: 18, scale: 2
      t.decimal :equity, precision: 18, scale: 2
      t.decimal :portfolio_value, precision: 18, scale: 2
      t.datetime :fetched_at, null: false
      t.jsonb :raw_account, default: {}, null: false

      t.timestamps
    end

    add_index :broker_account_snapshots, [:broker, :fetched_at]
  end
end
