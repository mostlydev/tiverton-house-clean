# frozen_string_literal: true

class CreateTickerDividendSnapshots < ActiveRecord::Migration[7.2]
  def change
    create_table :ticker_dividend_snapshots do |t|
      t.string :ticker, null: false
      t.string :source, null: false
      t.datetime :observed_at, null: false
      t.date :next_ex_date
      t.date :next_pay_date
      t.decimal :dividend_amount, precision: 18, scale: 8
      t.decimal :annualized_dividend, precision: 18, scale: 8
      t.decimal :dividend_yield, precision: 12, scale: 8
      t.decimal :yield_change_30d, precision: 12, scale: 8
      t.decimal :payout_ratio, precision: 12, scale: 8
      t.decimal :payout_growth_yoy, precision: 12, scale: 8
      t.jsonb :meta, null: false, default: {}
      t.timestamps
    end

    add_index :ticker_dividend_snapshots, [:ticker, :observed_at], name: 'idx_dividend_snapshots_ticker_time'
    add_index :ticker_dividend_snapshots, [:ticker, :source, :observed_at], name: 'idx_dividend_snapshots_source_time'
    add_index :ticker_dividend_snapshots, :next_ex_date
  end
end
