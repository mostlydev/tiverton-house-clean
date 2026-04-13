class CreatePriceSamples < ActiveRecord::Migration[7.2]
  def change
    create_table :price_samples do |t|
      t.string :ticker, null: false
      t.decimal :price, precision: 10, scale: 2, null: false
      t.datetime :sampled_at, null: false
      t.string :sample_minute, null: false
      t.string :source

      t.timestamps
    end

    add_index :price_samples, [:ticker, :sample_minute], unique: true, name: 'idx_price_samples_unique_minute'
    add_index :price_samples, [:ticker, :sampled_at], name: 'idx_price_samples_ticker_time'
    add_index :price_samples, :sampled_at, name: 'idx_price_samples_sampled_at'
  end
end
