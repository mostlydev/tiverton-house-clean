# frozen_string_literal: true

class EnforceBrokerFillOrderLink < ActiveRecord::Migration[7.2]
  def change
    change_column_null :broker_fills, :broker_order_id, false
  end
end
