class IncreaseTickerMetricsValuePrecision < ActiveRecord::Migration[7.2]
  def change
    # precision: 20, scale: 8 only allows 12 integer digits (max ~1 trillion).
    # Financial statement values (e.g. Apple revenue ~$143B, shares ~15B) can exceed that.
    # Increase to precision: 30, scale: 8 for 22 integer digits.
    change_column :ticker_metrics, :value, :decimal, precision: 30, scale: 8, null: false
  end
end
