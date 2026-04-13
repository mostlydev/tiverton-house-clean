# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[7.2].define(version: 2026_04_03_163000) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "plpgsql"

  create_table "agents", force: :cascade do |t|
    t.string "agent_id", null: false
    t.string "name", null: false
    t.string "role", null: false
    t.string "style"
    t.string "status", default: "active", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "default_execution_policy", default: "allow_extended", null: false
    t.index ["agent_id"], name: "index_agents_on_agent_id", unique: true
    t.index ["default_execution_policy"], name: "index_agents_on_default_execution_policy"
    t.check_constraint "default_execution_policy::text = ANY (ARRAY['immediate'::character varying, 'allow_extended'::character varying, 'queue_until_open'::character varying]::text[])", name: "check_agent_default_execution_policy"
    t.check_constraint "role::text = ANY (ARRAY['trader'::character varying::text, 'infrastructure'::character varying::text])", name: "check_agent_role"
    t.check_constraint "status::text = ANY (ARRAY['active'::character varying::text, 'paused'::character varying::text, 'disabled'::character varying::text])", name: "check_agent_status"
  end

  create_table "broker_account_activities", force: :cascade do |t|
    t.string "broker_activity_id", null: false
    t.string "activity_type", null: false
    t.string "ticker"
    t.decimal "qty", precision: 18, scale: 12
    t.decimal "price", precision: 18, scale: 4
    t.decimal "net_amount", precision: 18, scale: 2
    t.datetime "activity_date", null: false
    t.string "description"
    t.jsonb "raw_activity", default: {}
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["activity_type", "activity_date"], name: "idx_on_activity_type_activity_date_b073d57c3d"
    t.index ["broker_activity_id"], name: "index_broker_account_activities_on_broker_activity_id", unique: true
    t.index ["ticker"], name: "index_broker_account_activities_on_ticker"
  end

  create_table "broker_account_snapshots", force: :cascade do |t|
    t.string "broker", default: "alpaca", null: false
    t.decimal "cash", precision: 18, scale: 2
    t.decimal "buying_power", precision: 18, scale: 2
    t.decimal "equity", precision: 18, scale: 2
    t.decimal "portfolio_value", precision: 18, scale: 2
    t.datetime "fetched_at", null: false
    t.jsonb "raw_account", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["broker", "fetched_at"], name: "index_broker_account_snapshots_on_broker_and_fetched_at"
  end

  create_table "broker_fills", force: :cascade do |t|
    t.string "broker_fill_id"
    t.bigint "broker_order_id", null: false
    t.bigint "trade_id", null: false
    t.bigint "agent_id", null: false
    t.string "ticker", null: false
    t.string "side", null: false
    t.decimal "qty", precision: 18, scale: 12, null: false
    t.decimal "price", precision: 18, scale: 4, null: false
    t.decimal "value", precision: 18, scale: 2
    t.datetime "executed_at", null: false
    t.string "fill_id_confidence", default: "broker_verified"
    t.boolean "bootstrap_adjusted", default: false
    t.bigint "reconciliation_provenance_id"
    t.jsonb "raw_fill", default: {}
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["agent_id", "executed_at"], name: "index_broker_fills_on_agent_id_and_executed_at"
    t.index ["agent_id"], name: "index_broker_fills_on_agent_id"
    t.index ["broker_fill_id"], name: "index_broker_fills_on_broker_fill_id", unique: true, where: "(broker_fill_id IS NOT NULL)"
    t.index ["broker_fill_id"], name: "index_broker_fills_on_broker_fill_id_unique", unique: true, where: "(broker_fill_id IS NOT NULL)"
    t.index ["broker_order_id", "executed_at", "qty"], name: "idx_broker_fills_composite_unique", unique: true
    t.index ["broker_order_id"], name: "index_broker_fills_on_broker_order_id"
    t.index ["fill_id_confidence"], name: "index_broker_fills_on_fill_id_confidence"
    t.index ["reconciliation_provenance_id"], name: "index_broker_fills_on_reconciliation_provenance_id"
    t.index ["ticker", "executed_at"], name: "index_broker_fills_on_ticker_and_executed_at"
    t.index ["trade_id"], name: "index_broker_fills_on_trade_id"
    t.check_constraint "qty > 0::numeric", name: "broker_fills_qty_positive"
  end

  create_table "broker_order_events", force: :cascade do |t|
    t.bigint "broker_order_id", null: false
    t.string "event_type", null: false
    t.datetime "broker_event_ts", null: false
    t.integer "event_seq", default: 0
    t.decimal "qty_filled", precision: 18, scale: 8
    t.decimal "avg_fill_price", precision: 18, scale: 4
    t.decimal "cumulative_qty", precision: 18, scale: 8
    t.jsonb "raw_event", default: {}
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["broker_event_ts"], name: "index_broker_order_events_on_broker_event_ts"
    t.index ["broker_order_id", "event_type", "broker_event_ts", "event_seq"], name: "idx_broker_order_events_unique", unique: true
    t.index ["broker_order_id"], name: "index_broker_order_events_on_broker_order_id"
  end

  create_table "broker_orders", force: :cascade do |t|
    t.string "broker_order_id", null: false
    t.string "client_order_id", null: false
    t.bigint "trade_id", null: false
    t.bigint "agent_id", null: false
    t.string "ticker", null: false
    t.string "side", null: false
    t.string "intent_side"
    t.string "order_type", null: false
    t.string "time_in_force"
    t.string "requested_tif"
    t.string "effective_tif"
    t.string "transform_reason"
    t.boolean "extended_hours", default: false
    t.decimal "qty_requested", precision: 18, scale: 12
    t.decimal "notional_requested", precision: 18, scale: 2
    t.decimal "limit_price", precision: 18, scale: 4
    t.decimal "stop_price", precision: 18, scale: 4
    t.decimal "trail_percent", precision: 8, scale: 4
    t.decimal "trail_price", precision: 18, scale: 4
    t.string "status"
    t.datetime "submitted_at"
    t.datetime "filled_at"
    t.jsonb "raw_request", default: {}
    t.jsonb "raw_response", default: {}
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "asset_class", default: "us_equity", null: false
    t.index ["agent_id", "submitted_at"], name: "index_broker_orders_on_agent_id_and_submitted_at"
    t.index ["agent_id"], name: "index_broker_orders_on_agent_id"
    t.index ["asset_class"], name: "index_broker_orders_on_asset_class"
    t.index ["broker_order_id"], name: "index_broker_orders_on_broker_order_id", unique: true
    t.index ["client_order_id"], name: "index_broker_orders_on_client_order_id", unique: true
    t.index ["ticker", "status"], name: "index_broker_orders_on_ticker_and_status"
    t.index ["trade_id"], name: "index_broker_orders_on_trade_id"
    t.check_constraint "asset_class::text = ANY (ARRAY['us_equity'::character varying, 'us_option'::character varying, 'crypto'::character varying, 'crypto_perp'::character varying]::text[])", name: "check_broker_order_asset_class"
  end

  create_table "ledger_adjustments", force: :cascade do |t|
    t.bigint "ledger_transaction_id"
    t.bigint "reconciliation_provenance_id"
    t.string "reason_code", null: false
    t.text "reason_description"
    t.string "approver"
    t.string "evidence_artifact_path"
    t.jsonb "before_state", default: {}
    t.jsonb "after_state", default: {}
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["ledger_transaction_id"], name: "index_ledger_adjustments_on_ledger_transaction_id"
    t.index ["reason_code"], name: "index_ledger_adjustments_on_reason_code"
    t.index ["reconciliation_provenance_id"], name: "index_ledger_adjustments_on_reconciliation_provenance_id"
  end

  create_table "ledger_entries", force: :cascade do |t|
    t.bigint "ledger_transaction_id", null: false
    t.integer "entry_seq", null: false
    t.string "account_code", null: false
    t.decimal "amount", precision: 18, scale: 8, null: false
    t.string "asset", null: false
    t.bigint "agent_id"
    t.boolean "bootstrap_adjusted", default: false
    t.bigint "reconciliation_provenance_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_code"], name: "index_ledger_entries_on_account_code"
    t.index ["agent_id", "asset"], name: "index_ledger_entries_on_agent_id_and_asset"
    t.index ["agent_id"], name: "index_ledger_entries_on_agent_id"
    t.index ["ledger_transaction_id", "entry_seq"], name: "index_ledger_entries_on_ledger_transaction_id_and_entry_seq", unique: true
    t.index ["ledger_transaction_id"], name: "idx_ledger_entries_txn_balance"
    t.index ["ledger_transaction_id"], name: "index_ledger_entries_on_ledger_transaction_id"
    t.index ["reconciliation_provenance_id"], name: "index_ledger_entries_on_reconciliation_provenance_id"
  end

  create_table "ledger_transactions", force: :cascade do |t|
    t.string "ledger_txn_id", null: false
    t.string "source_type", null: false
    t.bigint "source_id"
    t.bigint "agent_id"
    t.string "asset"
    t.datetime "booked_at", null: false
    t.string "description"
    t.boolean "bootstrap_adjusted", default: false
    t.bigint "reconciliation_provenance_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["agent_id"], name: "index_ledger_transactions_on_agent_id"
    t.index ["booked_at"], name: "index_ledger_transactions_on_booked_at"
    t.index ["ledger_txn_id"], name: "index_ledger_transactions_on_ledger_txn_id", unique: true
    t.index ["reconciliation_provenance_id"], name: "index_ledger_transactions_on_reconciliation_provenance_id"
    t.index ["source_type", "source_id"], name: "index_ledger_transactions_on_source_type_and_source_id", unique: true
  end

  create_table "news_articles", force: :cascade do |t|
    t.string "external_id", null: false
    t.string "headline"
    t.string "source"
    t.text "content"
    t.text "summary"
    t.string "url"
    t.datetime "published_at"
    t.datetime "fetched_at"
    t.string "file_path"
    t.jsonb "raw_json", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["external_id"], name: "index_news_articles_on_external_id", unique: true
    t.index ["published_at"], name: "index_news_articles_on_published_at"
    t.index ["source"], name: "index_news_articles_on_source"
  end

  create_table "news_dispatches", force: :cascade do |t|
    t.string "batch_type", default: "news", null: false
    t.string "status", default: "pending", null: false
    t.string "confirmation_token", null: false
    t.text "message", null: false
    t.text "response"
    t.text "error"
    t.datetime "sent_at"
    t.datetime "confirmed_at"
    t.jsonb "article_ids", default: [], null: false
    t.jsonb "metadata", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["confirmation_token"], name: "index_news_dispatches_on_confirmation_token", unique: true
    t.index ["status"], name: "index_news_dispatches_on_status"
  end

  create_table "news_notifications", force: :cascade do |t|
    t.bigint "agent_id", null: false
    t.string "symbol", null: false
    t.datetime "notified_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["agent_id", "symbol"], name: "index_news_notifications_on_agent_id_and_symbol", unique: true
    t.index ["agent_id"], name: "index_news_notifications_on_agent_id"
  end

  create_table "news_summaries", force: :cascade do |t|
    t.string "summary_type", null: false
    t.text "body", null: false
    t.jsonb "metadata", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["summary_type"], name: "index_news_summaries_on_summary_type"
  end

  create_table "news_symbols", force: :cascade do |t|
    t.bigint "news_article_id", null: false
    t.string "symbol", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["news_article_id", "symbol"], name: "index_news_symbols_on_news_article_id_and_symbol", unique: true
    t.index ["news_article_id"], name: "index_news_symbols_on_news_article_id"
    t.index ["symbol"], name: "index_news_symbols_on_symbol"
  end

  create_table "outbox_events", force: :cascade do |t|
    t.string "event_type", null: false
    t.string "aggregate_type", null: false
    t.bigint "aggregate_id", null: false
    t.string "sequence_key"
    t.jsonb "payload", default: {}
    t.string "status", default: "pending"
    t.integer "attempts", default: 0
    t.datetime "scheduled_at", null: false
    t.datetime "processed_at"
    t.datetime "last_attempt_at"
    t.text "last_error"
    t.string "locked_by"
    t.datetime "locked_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["event_type", "aggregate_type", "aggregate_id", "sequence_key"], name: "idx_outbox_events_dedupe", unique: true
    t.index ["status", "scheduled_at"], name: "idx_outbox_events_pending"
    t.index ["status"], name: "idx_outbox_events_dead_letter", where: "((status)::text = 'dead_letter'::text)"
  end

  create_table "position_lots", force: :cascade do |t|
    t.bigint "agent_id", null: false
    t.string "ticker", null: false
    t.decimal "qty", precision: 18, scale: 12, null: false
    t.decimal "cost_basis_per_share", precision: 18, scale: 4, null: false
    t.decimal "total_cost_basis", precision: 18, scale: 2
    t.datetime "opened_at", null: false
    t.datetime "closed_at"
    t.string "open_source_type"
    t.bigint "open_source_id"
    t.string "close_source_type"
    t.bigint "close_source_id"
    t.decimal "realized_pnl", precision: 18, scale: 2
    t.boolean "bootstrap_adjusted", default: false
    t.bigint "reconciliation_provenance_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["agent_id", "ticker", "closed_at"], name: "idx_position_lots_open", where: "(closed_at IS NULL)"
    t.index ["agent_id", "ticker"], name: "index_position_lots_on_agent_id_and_ticker"
    t.index ["agent_id"], name: "index_position_lots_on_agent_id"
    t.index ["open_source_type", "open_source_id"], name: "index_position_lots_on_open_source_type_and_open_source_id"
    t.index ["reconciliation_provenance_id"], name: "index_position_lots_on_reconciliation_provenance_id"
    t.check_constraint "qty > 0::numeric", name: "position_lots_qty_positive"
  end

  create_table "positions", force: :cascade do |t|
    t.bigint "agent_id", null: false
    t.string "ticker", null: false
    t.decimal "qty", precision: 18, scale: 12, null: false
    t.decimal "avg_entry_price", precision: 15, scale: 4, null: false
    t.decimal "current_value", precision: 15, scale: 2
    t.datetime "opened_at", default: -> { "CURRENT_TIMESTAMP" }, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "asset_class", default: "us_equity", null: false
    t.decimal "stop_loss", precision: 15, scale: 4
    t.bigint "stop_loss_source_trade_id"
    t.datetime "stop_loss_triggered_at"
    t.datetime "stop_loss_last_alert_at"
    t.integer "stop_loss_alert_count", default: 0, null: false
    t.index ["agent_id", "ticker"], name: "index_positions_on_agent_id_and_ticker", unique: true
    t.index ["agent_id"], name: "index_positions_on_agent_id"
    t.index ["asset_class"], name: "index_positions_on_asset_class"
    t.index ["stop_loss_source_trade_id"], name: "index_positions_on_stop_loss_source_trade_id"
    t.check_constraint "asset_class::text = ANY (ARRAY['us_equity'::character varying, 'us_option'::character varying, 'crypto'::character varying, 'crypto_perp'::character varying]::text[])", name: "check_position_asset_class"
    t.check_constraint "qty = 0::numeric OR stop_loss IS NOT NULL", name: "check_open_positions_have_stop_loss"
    t.check_constraint "stop_loss IS NULL OR stop_loss > 0::numeric", name: "check_position_stop_loss_positive"
  end

  create_table "price_samples", force: :cascade do |t|
    t.string "ticker", null: false
    t.decimal "price", precision: 10, scale: 2, null: false
    t.string "asset_class"
    t.decimal "open_price", precision: 18, scale: 8
    t.decimal "high_price", precision: 18, scale: 8
    t.decimal "low_price", precision: 18, scale: 8
    t.decimal "close_price", precision: 18, scale: 8
    t.decimal "volume", precision: 20, scale: 8
    t.integer "trade_count"
    t.decimal "vwap", precision: 18, scale: 8
    t.datetime "sampled_at", null: false
    t.string "sample_minute", null: false
    t.string "source"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["sampled_at"], name: "idx_price_samples_sampled_at"
    t.index ["ticker", "sample_minute"], name: "idx_price_samples_unique_minute", unique: true
    t.index ["ticker", "sampled_at"], name: "idx_price_samples_ticker_time"
  end

  create_table "reconciliation_diffs", force: :cascade do |t|
    t.bigint "reconciliation_run_id", null: false
    t.string "entity_type", null: false
    t.string "entity_key"
    t.string "severity", null: false
    t.string "diff_type", null: false
    t.jsonb "expected_state", default: {}
    t.jsonb "actual_state", default: {}
    t.string "resolution_status", default: "open"
    t.string "resolution_action"
    t.bigint "ledger_adjustment_id"
    t.string "owner"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["entity_type", "entity_key"], name: "index_reconciliation_diffs_on_entity_type_and_entity_key"
    t.index ["ledger_adjustment_id"], name: "index_reconciliation_diffs_on_ledger_adjustment_id"
    t.index ["reconciliation_run_id", "severity"], name: "idx_on_reconciliation_run_id_severity_514c51379b"
    t.index ["reconciliation_run_id"], name: "index_reconciliation_diffs_on_reconciliation_run_id"
    t.index ["resolution_status"], name: "index_reconciliation_diffs_on_resolution_status"
  end

  create_table "reconciliation_provenances", force: :cascade do |t|
    t.string "run_id", null: false
    t.string "runner_script", null: false
    t.string "runner_version"
    t.jsonb "invocation_params", default: {}
    t.string "assignment_strategy"
    t.string "input_checksum"
    t.string "output_checksum"
    t.string "operator"
    t.datetime "started_at", null: false
    t.datetime "completed_at"
    t.text "report_paths"
    t.text "notes"
    t.string "status", default: "completed"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["input_checksum", "output_checksum", "runner_script"], name: "idx_recon_prov_checksums_script", unique: true
    t.index ["run_id"], name: "index_reconciliation_provenances_on_run_id", unique: true
    t.index ["started_at"], name: "index_reconciliation_provenances_on_started_at"
  end

  create_table "reconciliation_runs", force: :cascade do |t|
    t.string "run_id", null: false
    t.string "scope", null: false
    t.datetime "started_at", null: false
    t.datetime "completed_at"
    t.string "status", default: "running"
    t.jsonb "thresholds", default: {}
    t.boolean "pause_flag", default: false
    t.integer "diffs_green", default: 0
    t.integer "diffs_yellow", default: 0
    t.integer "diffs_red", default: 0
    t.text "summary"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["run_id"], name: "index_reconciliation_runs_on_run_id", unique: true
    t.index ["scope", "started_at"], name: "index_reconciliation_runs_on_scope_and_started_at"
    t.index ["status"], name: "index_reconciliation_runs_on_status"
  end

  create_table "ticker_dividend_snapshots", force: :cascade do |t|
    t.string "ticker", null: false
    t.string "source", null: false
    t.datetime "observed_at", null: false
    t.date "next_ex_date"
    t.date "next_pay_date"
    t.decimal "dividend_amount", precision: 18, scale: 8
    t.decimal "annualized_dividend", precision: 18, scale: 8
    t.decimal "dividend_yield", precision: 12, scale: 8
    t.decimal "yield_change_30d", precision: 12, scale: 8
    t.decimal "payout_ratio", precision: 12, scale: 8
    t.decimal "payout_growth_yoy", precision: 12, scale: 8
    t.jsonb "meta", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["next_ex_date"], name: "index_ticker_dividend_snapshots_on_next_ex_date"
    t.index ["ticker", "observed_at"], name: "idx_dividend_snapshots_ticker_time"
    t.index ["ticker", "source", "observed_at"], name: "idx_dividend_snapshots_source_time"
  end

  create_table "ticker_metrics", force: :cascade do |t|
    t.string "ticker", null: false
    t.string "metric", null: false
    t.decimal "value", precision: 30, scale: 8, null: false
    t.string "period_type"
    t.date "period_start"
    t.date "period_end"
    t.integer "fiscal_year"
    t.integer "fiscal_quarter"
    t.boolean "is_derived", default: false, null: false
    t.datetime "observed_at", null: false
    t.string "source", null: false
    t.decimal "confidence", precision: 6, scale: 4
    t.jsonb "meta"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["ticker", "metric", "period_end", "observed_at"], name: "index_ticker_metrics_on_ticker_metric_time"
    t.index ["ticker", "metric", "source", "period_end", "observed_at"], name: "index_ticker_metrics_on_key_and_time"
  end

  create_table "trade_events", force: :cascade do |t|
    t.bigint "trade_id", null: false
    t.string "event_type", null: false
    t.string "actor", null: false
    t.jsonb "details", default: {}
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["created_at"], name: "index_trade_events_on_created_at"
    t.index ["trade_id"], name: "index_trade_events_on_trade_id"
  end

  create_table "trade_requests", force: :cascade do |t|
    t.string "request_id", null: false
    t.string "source", null: false
    t.string "source_message_id"
    t.string "normalized_payload_hash"
    t.bigint "agent_id"
    t.string "ticker"
    t.string "intent_side"
    t.string "order_type"
    t.decimal "qty_requested", precision: 18, scale: 12
    t.decimal "notional_requested", precision: 18, scale: 2
    t.string "status", default: "accepted"
    t.bigint "trade_id"
    t.text "rejection_reason"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["agent_id", "ticker", "created_at"], name: "index_trade_requests_on_agent_id_and_ticker_and_created_at"
    t.index ["agent_id"], name: "index_trade_requests_on_agent_id"
    t.index ["normalized_payload_hash"], name: "index_trade_requests_on_normalized_payload_hash"
    t.index ["request_id"], name: "index_trade_requests_on_request_id", unique: true
    t.index ["source_message_id"], name: "index_trade_requests_on_source_message_id"
    t.index ["trade_id"], name: "index_trade_requests_on_trade_id"
  end

  create_table "trades", force: :cascade do |t|
    t.string "trade_id", null: false
    t.bigint "agent_id", null: false
    t.string "ticker", null: false
    t.string "side", null: false
    t.decimal "qty_requested", precision: 18, scale: 12
    t.decimal "amount_requested", precision: 15, scale: 2
    t.string "order_type", default: "MARKET", null: false
    t.decimal "limit_price", precision: 15, scale: 4
    t.decimal "stop_price", precision: 15, scale: 4
    t.decimal "trail_percent", precision: 8, scale: 4
    t.decimal "trail_amount", precision: 15, scale: 4
    t.string "status", default: "PROPOSED", null: false
    t.text "thesis"
    t.decimal "stop_loss", precision: 15, scale: 4
    t.decimal "target_price", precision: 15, scale: 4
    t.boolean "is_urgent", default: false
    t.string "approved_by"
    t.datetime "approved_at"
    t.datetime "confirmed_at"
    t.text "denial_reason"
    t.text "execution_error"
    t.string "executed_by"
    t.datetime "execution_started_at"
    t.datetime "execution_completed_at"
    t.string "alpaca_order_id"
    t.decimal "qty_filled", precision: 18, scale: 12
    t.decimal "avg_fill_price", precision: 15, scale: 4
    t.decimal "filled_value", precision: 15, scale: 2
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.boolean "extended_hours", default: false, null: false
    t.string "asset_class", default: "us_equity", null: false
    t.string "execution_policy", default: "allow_extended", null: false
    t.datetime "queued_at"
    t.datetime "scheduled_for"
    t.index ["agent_id"], name: "index_trades_on_agent_id"
    t.index ["asset_class"], name: "index_trades_on_asset_class"
    t.index ["created_at"], name: "index_trades_on_created_at"
    t.index ["execution_policy"], name: "index_trades_on_execution_policy"
    t.index ["scheduled_for"], name: "index_trades_on_scheduled_for"
    t.index ["status"], name: "index_trades_on_status"
    t.index ["ticker"], name: "index_trades_on_ticker"
    t.index ["trade_id"], name: "index_trades_on_trade_id", unique: true
    t.check_constraint "(status::text <> ALL (ARRAY['FILLED'::character varying, 'PARTIALLY_FILLED'::character varying]::text[])) OR alpaca_order_id IS NOT NULL", name: "check_filled_has_alpaca_order_id"
    t.check_constraint "asset_class::text = ANY (ARRAY['us_equity'::character varying, 'us_option'::character varying, 'crypto'::character varying, 'crypto_perp'::character varying]::text[])", name: "check_trade_asset_class"
    t.check_constraint "execution_policy::text = ANY (ARRAY['immediate'::character varying, 'allow_extended'::character varying, 'queue_until_open'::character varying]::text[])", name: "check_trade_execution_policy"
    t.check_constraint "order_type::text = ANY (ARRAY['MARKET'::character varying::text, 'LIMIT'::character varying::text, 'STOP'::character varying::text, 'STOP_LIMIT'::character varying::text, 'TRAILING_STOP'::character varying::text])", name: "check_trade_order_type"
    t.check_constraint "side::text = ANY (ARRAY['BUY'::character varying::text, 'SELL'::character varying::text])", name: "check_trade_side"
    t.check_constraint "status::text = ANY (ARRAY['PROPOSED'::character varying, 'PENDING'::character varying, 'APPROVED'::character varying, 'QUEUED'::character varying, 'DENIED'::character varying, 'EXECUTING'::character varying, 'FILLED'::character varying, 'PARTIALLY_FILLED'::character varying, 'CANCELLED'::character varying, 'FAILED'::character varying, 'PASSED'::character varying]::text[])", name: "check_trade_status"
  end

  create_table "wallets", force: :cascade do |t|
    t.bigint "agent_id", null: false
    t.decimal "wallet_size", precision: 15, scale: 2, default: "20000.0", null: false
    t.decimal "cash", precision: 15, scale: 2, default: "20000.0", null: false
    t.decimal "invested", precision: 15, scale: 2, default: "0.0", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.datetime "last_synced_at"
    t.index ["agent_id"], name: "index_wallets_on_agent_id", unique: true
    t.index ["last_synced_at"], name: "index_wallets_on_last_synced_at"
  end

  create_table "watchlists", force: :cascade do |t|
    t.bigint "agent_id", null: false
    t.string "ticker", null: false
    t.string "source", default: "file", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["agent_id", "ticker", "source"], name: "idx_watchlists_unique", unique: true
    t.index ["agent_id"], name: "index_watchlists_on_agent_id"
    t.index ["ticker"], name: "index_watchlists_on_ticker"
  end

  add_foreign_key "broker_fills", "agents"
  add_foreign_key "broker_fills", "broker_orders"
  add_foreign_key "broker_fills", "reconciliation_provenances"
  add_foreign_key "broker_fills", "trades"
  add_foreign_key "broker_order_events", "broker_orders"
  add_foreign_key "broker_orders", "agents"
  add_foreign_key "broker_orders", "trades"
  add_foreign_key "ledger_adjustments", "ledger_transactions"
  add_foreign_key "ledger_adjustments", "reconciliation_provenances"
  add_foreign_key "ledger_entries", "agents"
  add_foreign_key "ledger_entries", "ledger_transactions"
  add_foreign_key "ledger_entries", "reconciliation_provenances"
  add_foreign_key "ledger_transactions", "agents"
  add_foreign_key "ledger_transactions", "reconciliation_provenances"
  add_foreign_key "news_notifications", "agents"
  add_foreign_key "news_symbols", "news_articles"
  add_foreign_key "position_lots", "agents"
  add_foreign_key "position_lots", "reconciliation_provenances"
  add_foreign_key "positions", "agents"
  add_foreign_key "reconciliation_diffs", "ledger_adjustments"
  add_foreign_key "reconciliation_diffs", "reconciliation_runs"
  add_foreign_key "trade_events", "trades"
  add_foreign_key "trade_requests", "agents"
  add_foreign_key "trade_requests", "trades"
  add_foreign_key "trades", "agents"
  add_foreign_key "wallets", "agents"
  add_foreign_key "watchlists", "agents"
end
