# frozen_string_literal: true

# Transaction Ledger Migration v5 - Core Schema
#
# Creates the event-sourced accounting schema with projections:
# - Intent/Workflow layer: trade_requests
# - Broker fact layer: broker_orders, broker_order_events, broker_fills, broker_account_activities
# - Ledger layer: ledger_transactions, ledger_entries
# - Inventory layer: position_lots
# - Reconciliation layer: reconciliation_runs, reconciliation_diffs, ledger_adjustments
class CreateLedgerTables < ActiveRecord::Migration[7.2]
  def change
    # ========================================
    # 1. INTENT LAYER: trade_requests
    # ========================================
    create_table :trade_requests do |t|
      t.string :request_id, null: false
      t.string :source, null: false  # discord, api, system
      t.string :source_message_id
      t.string :normalized_payload_hash
      t.references :agent, foreign_key: true
      t.string :ticker
      t.string :intent_side  # BUY_TO_OPEN, SELL_TO_CLOSE, SELL_TO_OPEN, BUY_TO_CLOSE
      t.string :order_type
      t.decimal :qty_requested, precision: 18, scale: 8
      t.decimal :notional_requested, precision: 18, scale: 2
      t.string :status, default: 'accepted'  # accepted, duplicate, rejected
      t.references :trade, foreign_key: true
      t.text :rejection_reason

      t.timestamps
    end
    add_index :trade_requests, :request_id, unique: true
    add_index :trade_requests, :source_message_id
    add_index :trade_requests, :normalized_payload_hash
    add_index :trade_requests, [:agent_id, :ticker, :created_at]

    # ========================================
    # 2. BROKER FACT LAYER: broker_orders
    # ========================================
    create_table :broker_orders do |t|
      t.string :broker_order_id, null: false
      t.string :client_order_id, null: false
      t.references :trade, foreign_key: true
      t.references :agent, foreign_key: true
      t.string :ticker, null: false
      t.string :side, null: false  # buy, sell
      t.string :intent_side  # BUY_TO_OPEN, SELL_TO_CLOSE, etc.
      t.string :order_type, null: false
      t.string :time_in_force
      t.string :requested_tif
      t.string :effective_tif
      t.string :transform_reason
      t.boolean :extended_hours, default: false
      t.decimal :qty_requested, precision: 18, scale: 8
      t.decimal :notional_requested, precision: 18, scale: 2
      t.decimal :limit_price, precision: 18, scale: 4
      t.decimal :stop_price, precision: 18, scale: 4
      t.decimal :trail_percent, precision: 8, scale: 4
      t.decimal :trail_price, precision: 18, scale: 4
      t.string :status
      t.datetime :submitted_at
      t.datetime :filled_at
      t.jsonb :raw_request, default: {}
      t.jsonb :raw_response, default: {}

      t.timestamps
    end
    add_index :broker_orders, :broker_order_id, unique: true
    add_index :broker_orders, :client_order_id, unique: true
    add_index :broker_orders, [:ticker, :status]
    add_index :broker_orders, [:agent_id, :submitted_at]

    # ========================================
    # 3. BROKER FACT LAYER: broker_order_events
    # ========================================
    create_table :broker_order_events do |t|
      t.references :broker_order, foreign_key: true, null: false
      t.string :event_type, null: false  # new, accepted, partial_fill, filled, canceled, replaced, rejected
      t.datetime :broker_event_ts, null: false
      t.integer :event_seq, default: 0
      t.decimal :qty_filled, precision: 18, scale: 8
      t.decimal :avg_fill_price, precision: 18, scale: 4
      t.decimal :cumulative_qty, precision: 18, scale: 8
      t.jsonb :raw_event, default: {}

      t.timestamps
    end
    add_index :broker_order_events, [:broker_order_id, :event_type, :broker_event_ts, :event_seq],
              unique: true, name: 'idx_broker_order_events_unique'
    add_index :broker_order_events, :broker_event_ts

    # ========================================
    # 4. BROKER FACT LAYER: broker_fills
    # ========================================
    create_table :broker_fills do |t|
      t.string :broker_fill_id
      t.references :broker_order, foreign_key: true  # Creates broker_order_id
      t.references :trade, foreign_key: true
      t.references :agent, foreign_key: true
      t.string :ticker, null: false
      t.string :side, null: false
      t.decimal :qty, precision: 18, scale: 8, null: false
      t.decimal :price, precision: 18, scale: 4, null: false
      t.decimal :value, precision: 18, scale: 2
      t.datetime :executed_at, null: false
      t.string :fill_id_confidence, default: 'broker_verified'  # broker_verified, order_derived, price_interpolated, reconciliation_assigned
      t.boolean :bootstrap_adjusted, default: false
      t.references :reconciliation_provenance, foreign_key: true
      t.jsonb :raw_fill, default: {}

      t.timestamps
    end
    # Unique on broker_fill_id when present, or composite fallback
    add_index :broker_fills, :broker_fill_id, unique: true, where: 'broker_fill_id IS NOT NULL'
    # Note: broker_order_id comes from t.references :broker_order above
    add_index :broker_fills, [:broker_order_id, :executed_at, :qty], unique: true, name: 'idx_broker_fills_composite_unique'
    add_index :broker_fills, [:ticker, :executed_at]
    add_index :broker_fills, [:agent_id, :executed_at]
    add_index :broker_fills, :fill_id_confidence

    # ========================================
    # 5. BROKER FACT LAYER: broker_account_activities
    # ========================================
    create_table :broker_account_activities do |t|
      t.string :broker_activity_id, null: false
      t.string :activity_type, null: false  # DIV, FEE, JNLC, JNLS, CSR, etc.
      t.string :ticker
      t.decimal :qty, precision: 18, scale: 8
      t.decimal :price, precision: 18, scale: 4
      t.decimal :net_amount, precision: 18, scale: 2
      t.datetime :activity_date, null: false
      t.string :description
      t.jsonb :raw_activity, default: {}

      t.timestamps
    end
    add_index :broker_account_activities, :broker_activity_id, unique: true
    add_index :broker_account_activities, [:activity_type, :activity_date]
    add_index :broker_account_activities, :ticker

    # ========================================
    # 6. LEDGER LAYER: ledger_transactions
    # ========================================
    create_table :ledger_transactions do |t|
      t.string :ledger_txn_id, null: false
      t.string :source_type, null: false  # broker_fill, broker_activity, adjustment, bootstrap
      t.bigint :source_id
      t.references :agent, foreign_key: true
      t.string :asset  # USD, ticker symbol
      t.datetime :booked_at, null: false
      t.string :description
      t.boolean :bootstrap_adjusted, default: false
      t.references :reconciliation_provenance, foreign_key: true

      t.timestamps
    end
    add_index :ledger_transactions, :ledger_txn_id, unique: true
    add_index :ledger_transactions, [:source_type, :source_id], unique: true
    add_index :ledger_transactions, :booked_at

    # ========================================
    # 7. LEDGER LAYER: ledger_entries
    # ========================================
    create_table :ledger_entries do |t|
      t.references :ledger_transaction, foreign_key: true, null: false
      t.integer :entry_seq, null: false
      t.string :account_code, null: false  # e.g., 'agent:dundas:cash', 'agent:dundas:AAPL', 'alpaca_cash_control'
      t.decimal :amount, precision: 18, scale: 8, null: false  # positive = debit, negative = credit
      t.string :asset, null: false  # USD or ticker
      t.references :agent, foreign_key: true
      t.boolean :bootstrap_adjusted, default: false
      t.references :reconciliation_provenance, foreign_key: true

      t.timestamps
    end
    add_index :ledger_entries, [:ledger_transaction_id, :entry_seq], unique: true
    add_index :ledger_entries, :account_code
    add_index :ledger_entries, [:agent_id, :asset]

    # ========================================
    # 8. INVENTORY LAYER: position_lots
    # ========================================
    create_table :position_lots do |t|
      t.references :agent, foreign_key: true, null: false
      t.string :ticker, null: false
      t.decimal :qty, precision: 18, scale: 8, null: false  # positive = long, negative = short
      t.decimal :cost_basis_per_share, precision: 18, scale: 4, null: false
      t.decimal :total_cost_basis, precision: 18, scale: 2
      t.datetime :opened_at, null: false
      t.datetime :closed_at
      t.string :open_source_type  # broker_fill, bootstrap, adjustment
      t.bigint :open_source_id
      t.string :close_source_type
      t.bigint :close_source_id
      t.decimal :realized_pnl, precision: 18, scale: 2
      t.boolean :bootstrap_adjusted, default: false
      t.references :reconciliation_provenance, foreign_key: true

      t.timestamps
    end
    add_index :position_lots, [:agent_id, :ticker]
    add_index :position_lots, [:agent_id, :ticker, :closed_at], where: 'closed_at IS NULL', name: 'idx_position_lots_open'
    add_index :position_lots, [:open_source_type, :open_source_id]

    # ========================================
    # 9. LEDGER LAYER: ledger_adjustments
    # ========================================
    create_table :ledger_adjustments do |t|
      t.references :ledger_transaction, foreign_key: true
      t.references :reconciliation_provenance, foreign_key: true
      t.string :reason_code, null: false
      t.text :reason_description
      t.string :approver
      t.string :evidence_artifact_path
      t.jsonb :before_state, default: {}
      t.jsonb :after_state, default: {}

      t.timestamps
    end
    add_index :ledger_adjustments, :reason_code

    # ========================================
    # 10. RECONCILIATION LAYER: reconciliation_runs
    # ========================================
    create_table :reconciliation_runs do |t|
      t.string :run_id, null: false
      t.string :scope, null: false  # orders, fills, positions, cash, full
      t.datetime :started_at, null: false
      t.datetime :completed_at
      t.string :status, default: 'running'  # running, completed, failed, paused
      t.jsonb :thresholds, default: {}
      t.boolean :pause_flag, default: false
      t.integer :diffs_green, default: 0
      t.integer :diffs_yellow, default: 0
      t.integer :diffs_red, default: 0
      t.text :summary

      t.timestamps
    end
    add_index :reconciliation_runs, :run_id, unique: true
    add_index :reconciliation_runs, [:scope, :started_at]
    add_index :reconciliation_runs, :status

    # ========================================
    # 11. RECONCILIATION LAYER: reconciliation_diffs
    # ========================================
    create_table :reconciliation_diffs do |t|
      t.references :reconciliation_run, foreign_key: true, null: false
      t.string :entity_type, null: false  # order, fill, position, cash
      t.string :entity_key  # e.g., order_id, agent_id:ticker
      t.string :severity, null: false  # GREEN, YELLOW, RED
      t.string :diff_type, null: false  # missing, mismatch, unexpected
      t.jsonb :expected_state, default: {}
      t.jsonb :actual_state, default: {}
      t.string :resolution_status, default: 'open'  # open, resolved, ignored
      t.string :resolution_action
      t.references :ledger_adjustment, foreign_key: true
      t.string :owner

      t.timestamps
    end
    add_index :reconciliation_diffs, [:reconciliation_run_id, :severity]
    add_index :reconciliation_diffs, [:entity_type, :entity_key]
    add_index :reconciliation_diffs, :resolution_status
  end
end
