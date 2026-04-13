# frozen_string_literal: true

class EnforceBrokerOrderTradeAgentLinks < ActiveRecord::Migration[7.2]
  def change
    change_column_null :broker_orders, :trade_id, false
    change_column_null :broker_orders, :agent_id, false
    change_column_null :broker_fills, :trade_id, false
    change_column_null :broker_fills, :agent_id, false
  end
end
