class ChangeQtyToDecimal < ActiveRecord::Migration[7.0]
  def up
    change_column :positions, :qty, :decimal, precision: 18, scale: 6, null: false
    change_column :trades, :qty_requested, :decimal, precision: 18, scale: 6
    change_column :trades, :qty_filled, :decimal, precision: 18, scale: 6
  end

  def down
    change_column :positions, :qty, :integer, null: false
    change_column :trades, :qty_requested, :integer
    change_column :trades, :qty_filled, :integer
  end
end
