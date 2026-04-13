class ExpandAssetClassConstraints < ActiveRecord::Migration[7.0]
  def up
    execute <<~SQL
      ALTER TABLE trades
        DROP CONSTRAINT IF EXISTS check_trade_asset_class;
      ALTER TABLE trades
        ADD CONSTRAINT check_trade_asset_class
        CHECK (asset_class IN ('us_equity', 'us_option', 'crypto', 'crypto_perp'));

      ALTER TABLE positions
        DROP CONSTRAINT IF EXISTS check_position_asset_class;
      ALTER TABLE positions
        ADD CONSTRAINT check_position_asset_class
        CHECK (asset_class IN ('us_equity', 'us_option', 'crypto', 'crypto_perp'));

      ALTER TABLE broker_orders
        DROP CONSTRAINT IF EXISTS check_broker_order_asset_class;
      ALTER TABLE broker_orders
        ADD CONSTRAINT check_broker_order_asset_class
        CHECK (asset_class IN ('us_equity', 'us_option', 'crypto', 'crypto_perp'));
    SQL
  end

  def down
    execute <<~SQL
      ALTER TABLE trades
        DROP CONSTRAINT IF EXISTS check_trade_asset_class;
      ALTER TABLE trades
        ADD CONSTRAINT check_trade_asset_class
        CHECK (asset_class IN ('us_equity', 'crypto'));

      ALTER TABLE positions
        DROP CONSTRAINT IF EXISTS check_position_asset_class;
      ALTER TABLE positions
        ADD CONSTRAINT check_position_asset_class
        CHECK (asset_class IN ('us_equity', 'crypto'));

      ALTER TABLE broker_orders
        DROP CONSTRAINT IF EXISTS check_broker_order_asset_class;
      ALTER TABLE broker_orders
        ADD CONSTRAINT check_broker_order_asset_class
        CHECK (asset_class IN ('us_equity', 'crypto'));
    SQL
  end
end
