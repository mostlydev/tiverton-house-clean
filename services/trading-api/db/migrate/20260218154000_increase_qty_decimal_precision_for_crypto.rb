class IncreaseQtyDecimalPrecisionForCrypto < ActiveRecord::Migration[7.1]
  # Root cause: decimal(18,8) only stores 8 digits after decimal point.
  # Crypto quantities (e.g. ETH) can require 9+ decimal places.
  # Scale 8 rounds 0.093146125 → 0.09314613, causing Alpaca rejections.
  # Fix: increase scale to 12 across all qty columns.
  def up
    change_column :broker_account_activities, :qty, :decimal, precision: 18, scale: 12
    change_column :broker_fills, :qty, :decimal, precision: 18, scale: 12, null: false
    change_column :broker_orders, :qty_requested, :decimal, precision: 18, scale: 12
    change_column :position_lots, :qty, :decimal, precision: 18, scale: 12, null: false
    change_column :positions, :qty, :decimal, precision: 18, scale: 12, null: false
    change_column :trade_requests, :qty_requested, :decimal, precision: 18, scale: 12
    change_column :trades, :qty_requested, :decimal, precision: 18, scale: 12
    change_column :trades, :qty_filled, :decimal, precision: 18, scale: 12
  end

  def down
    change_column :broker_account_activities, :qty, :decimal, precision: 18, scale: 8
    change_column :broker_fills, :qty, :decimal, precision: 18, scale: 8, null: false
    change_column :broker_orders, :qty_requested, :decimal, precision: 18, scale: 8
    change_column :position_lots, :qty, :decimal, precision: 18, scale: 8, null: false
    change_column :positions, :qty, :decimal, precision: 18, scale: 8, null: false
    change_column :trade_requests, :qty_requested, :decimal, precision: 18, scale: 8
    change_column :trades, :qty_requested, :decimal, precision: 18, scale: 8
    change_column :trades, :qty_filled, :decimal, precision: 18, scale: 8
  end
end
