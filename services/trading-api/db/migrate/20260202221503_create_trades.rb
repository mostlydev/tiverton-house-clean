class CreateTrades < ActiveRecord::Migration[7.2]
  def change
    create_table :trades do |t|
      t.string :trade_id, null: false
      t.references :agent, null: false, foreign_key: true
      t.string :ticker, null: false
      t.string :side, null: false
      t.integer :qty_requested
      t.decimal :amount_requested, precision: 15, scale: 2
      t.string :order_type, null: false, default: 'MARKET'
      t.decimal :limit_price, precision: 15, scale: 4
      t.decimal :stop_price, precision: 15, scale: 4
      t.decimal :trail_percent, precision: 8, scale: 4
      t.decimal :trail_amount, precision: 15, scale: 4
      t.string :status, null: false, default: 'PROPOSED'
      t.text :thesis
      t.decimal :stop_loss, precision: 15, scale: 4
      t.decimal :target_price, precision: 15, scale: 4
      t.boolean :is_urgent, default: false
      t.string :approved_by
      t.datetime :approved_at
      t.datetime :confirmed_at
      t.text :denial_reason
      t.text :execution_error
      t.string :executed_by
      t.datetime :execution_started_at
      t.datetime :execution_completed_at
      t.string :alpaca_order_id
      t.integer :qty_filled
      t.decimal :avg_fill_price, precision: 15, scale: 4
      t.decimal :filled_value, precision: 15, scale: 2

      t.timestamps
    end

    add_index :trades, :trade_id, unique: true
    add_index :trades, :ticker
    add_index :trades, :status
    add_index :trades, :created_at

    # Add check constraints
    execute <<-SQL
      ALTER TABLE trades
      ADD CONSTRAINT check_trade_side
      CHECK (side IN ('BUY', 'SELL'));

      ALTER TABLE trades
      ADD CONSTRAINT check_trade_order_type
      CHECK (order_type IN ('MARKET', 'LIMIT', 'STOP', 'STOP_LIMIT', 'TRAILING_STOP'));

      ALTER TABLE trades
      ADD CONSTRAINT check_trade_status
      CHECK (status IN ('PROPOSED', 'PENDING', 'APPROVED', 'DENIED', 'EXECUTING',
                       'FILLED', 'PARTIALLY_FILLED', 'CANCELLED', 'FAILED', 'PASSED'));
    SQL
  end
end
