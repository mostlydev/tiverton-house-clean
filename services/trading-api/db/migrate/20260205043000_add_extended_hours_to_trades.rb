class AddExtendedHoursToTrades < ActiveRecord::Migration[7.2]
  def change
    add_column :trades, :extended_hours, :boolean, default: false, null: false
  end
end
