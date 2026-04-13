# frozen_string_literal: true

class CreateTickerMetrics < ActiveRecord::Migration[7.0]
  def change
    create_table :ticker_metrics do |t|
      t.string :ticker, null: false
      t.string :metric, null: false
      t.decimal :value, precision: 20, scale: 8, null: false
      t.string :period_type
      t.date :period_start
      t.date :period_end
      t.integer :fiscal_year
      t.integer :fiscal_quarter
      t.boolean :is_derived, null: false, default: false
      t.datetime :observed_at, null: false
      t.string :source, null: false
      t.decimal :confidence, precision: 6, scale: 4
      t.jsonb :meta

      t.timestamps
    end

    add_index :ticker_metrics, [ :ticker, :metric, :source, :period_end, :observed_at ],
              name: "index_ticker_metrics_on_key_and_time"
    add_index :ticker_metrics, [ :ticker, :metric, :period_end, :observed_at ],
              name: "index_ticker_metrics_on_ticker_metric_time"
  end
end
