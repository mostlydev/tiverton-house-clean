# frozen_string_literal: true

class ChangeQtyColumnsToDecimal < ActiveRecord::Migration[7.2]
  def up
    change_column :trades, :qty_requested, :decimal, precision: 18, scale: 8
    change_column :trades, :qty_filled, :decimal, precision: 18, scale: 8
    change_column :positions, :qty, :decimal, precision: 18, scale: 8, null: false
  end

  def down
    change_column :positions, :qty, :integer, null: false
    change_column :trades, :qty_filled, :integer
    change_column :trades, :qty_requested, :integer
  end
end
