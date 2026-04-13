# frozen_string_literal: true

class AddMarketBarFieldsToPriceSamples < ActiveRecord::Migration[7.2]
  def up
    add_column :price_samples, :asset_class, :string
    add_column :price_samples, :open_price, :decimal, precision: 18, scale: 8
    add_column :price_samples, :high_price, :decimal, precision: 18, scale: 8
    add_column :price_samples, :low_price, :decimal, precision: 18, scale: 8
    add_column :price_samples, :close_price, :decimal, precision: 18, scale: 8
    add_column :price_samples, :volume, :decimal, precision: 20, scale: 8
    add_column :price_samples, :trade_count, :integer
    add_column :price_samples, :vwap, :decimal, precision: 18, scale: 8

    execute <<~SQL
      UPDATE price_samples
      SET
        asset_class = CASE
          WHEN ticker LIKE '%/%' OR ticker ~ '^[A-Z]+USD$' THEN 'crypto'
          WHEN ticker ~ '^[A-Z]{1,6}[0-9]{6}[CP][0-9]{8}$' THEN 'us_option'
          ELSE 'us_equity'
        END,
        open_price = COALESCE(open_price, price),
        high_price = COALESCE(high_price, price),
        low_price = COALESCE(low_price, price),
        close_price = COALESCE(close_price, price),
        vwap = COALESCE(vwap, price)
    SQL
  end

  def down
    remove_column :price_samples, :vwap
    remove_column :price_samples, :trade_count
    remove_column :price_samples, :volume
    remove_column :price_samples, :close_price
    remove_column :price_samples, :low_price
    remove_column :price_samples, :high_price
    remove_column :price_samples, :open_price
    remove_column :price_samples, :asset_class
  end
end
