# frozen_string_literal: true

class AddAssetClassAndExecutionPolicy < ActiveRecord::Migration[7.2]
  def up
    add_column :trades, :asset_class, :string, default: "us_equity", null: false
    add_column :trades, :execution_policy, :string, default: "allow_extended", null: false
    add_column :trades, :queued_at, :datetime
    add_column :trades, :scheduled_for, :datetime

    add_column :positions, :asset_class, :string, default: "us_equity", null: false
    add_column :broker_orders, :asset_class, :string, default: "us_equity", null: false
    add_column :agents, :default_execution_policy, :string, default: "allow_extended", null: false

    add_index :trades, :asset_class
    add_index :trades, :execution_policy
    add_index :trades, :scheduled_for
    add_index :positions, :asset_class
    add_index :broker_orders, :asset_class
    add_index :agents, :default_execution_policy

    execute "ALTER TABLE trades DROP CONSTRAINT IF EXISTS check_trade_status"
    execute <<~SQL
      ALTER TABLE trades
      ADD CONSTRAINT check_trade_status
      CHECK (status IN (
        'PROPOSED', 'PENDING', 'APPROVED', 'QUEUED', 'DENIED', 'EXECUTING',
        'FILLED', 'PARTIALLY_FILLED', 'CANCELLED', 'FAILED', 'PASSED'
      ));
    SQL

    execute "ALTER TABLE trades DROP CONSTRAINT IF EXISTS check_trade_asset_class"
    execute <<~SQL
      ALTER TABLE trades
      ADD CONSTRAINT check_trade_asset_class
      CHECK (asset_class IN ('us_equity', 'us_option', 'crypto', 'crypto_perp'));
    SQL

    execute "ALTER TABLE trades DROP CONSTRAINT IF EXISTS check_trade_execution_policy"
    execute <<~SQL
      ALTER TABLE trades
      ADD CONSTRAINT check_trade_execution_policy
      CHECK (execution_policy IN ('immediate', 'allow_extended', 'queue_until_open'));
    SQL

    execute "ALTER TABLE positions DROP CONSTRAINT IF EXISTS check_position_asset_class"
    execute <<~SQL
      ALTER TABLE positions
      ADD CONSTRAINT check_position_asset_class
      CHECK (asset_class IN ('us_equity', 'us_option', 'crypto', 'crypto_perp'));
    SQL

    execute "ALTER TABLE broker_orders DROP CONSTRAINT IF EXISTS check_broker_order_asset_class"
    execute <<~SQL
      ALTER TABLE broker_orders
      ADD CONSTRAINT check_broker_order_asset_class
      CHECK (asset_class IN ('us_equity', 'us_option', 'crypto', 'crypto_perp'));
    SQL

    execute "ALTER TABLE agents DROP CONSTRAINT IF EXISTS check_agent_default_execution_policy"
    execute <<~SQL
      ALTER TABLE agents
      ADD CONSTRAINT check_agent_default_execution_policy
      CHECK (default_execution_policy IN ('immediate', 'allow_extended', 'queue_until_open'));
    SQL
  end

  def down
    execute "ALTER TABLE trades DROP CONSTRAINT IF EXISTS check_trade_status"
    execute <<~SQL
      ALTER TABLE trades
      ADD CONSTRAINT check_trade_status
      CHECK (status IN (
        'PROPOSED', 'PENDING', 'APPROVED', 'DENIED', 'EXECUTING',
        'FILLED', 'PARTIALLY_FILLED', 'CANCELLED', 'FAILED', 'PASSED'
      ));
    SQL

    execute "ALTER TABLE trades DROP CONSTRAINT IF EXISTS check_trade_asset_class"
    execute "ALTER TABLE trades DROP CONSTRAINT IF EXISTS check_trade_execution_policy"
    execute "ALTER TABLE positions DROP CONSTRAINT IF EXISTS check_position_asset_class"
    execute "ALTER TABLE broker_orders DROP CONSTRAINT IF EXISTS check_broker_order_asset_class"
    execute "ALTER TABLE agents DROP CONSTRAINT IF EXISTS check_agent_default_execution_policy"

    remove_index :agents, :default_execution_policy if index_exists?(:agents, :default_execution_policy)
    remove_index :broker_orders, :asset_class if index_exists?(:broker_orders, :asset_class)
    remove_index :positions, :asset_class if index_exists?(:positions, :asset_class)
    remove_index :trades, :scheduled_for if index_exists?(:trades, :scheduled_for)
    remove_index :trades, :execution_policy if index_exists?(:trades, :execution_policy)
    remove_index :trades, :asset_class if index_exists?(:trades, :asset_class)

    remove_column :agents, :default_execution_policy
    remove_column :broker_orders, :asset_class
    remove_column :positions, :asset_class
    remove_column :trades, :scheduled_for
    remove_column :trades, :queued_at
    remove_column :trades, :execution_policy
    remove_column :trades, :asset_class
  end
end
