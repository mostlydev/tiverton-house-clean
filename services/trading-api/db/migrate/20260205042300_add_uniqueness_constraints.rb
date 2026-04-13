# frozen_string_literal: true

class AddUniquenessConstraints < ActiveRecord::Migration[7.2]
  def change
    # Prevent duplicate fills from being imported
    # broker_fill_id is the Alpaca-provided unique fill identifier
    add_index :broker_fills, :broker_fill_id, unique: true, where: "broker_fill_id IS NOT NULL",
              name: "index_broker_fills_on_broker_fill_id_unique"

    # Add check constraint to prevent negative quantities on position lots
    # (sells should close lots, not create negative ones)
    add_check_constraint :position_lots, "qty > 0", name: "position_lots_qty_positive"

    # Add check constraint to prevent negative quantities on broker fills
    add_check_constraint :broker_fills, "qty > 0", name: "broker_fills_qty_positive"
  end
end
