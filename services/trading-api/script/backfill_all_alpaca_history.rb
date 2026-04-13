#!/usr/bin/env ruby
# frozen_string_literal: true

# Backfill ALL Alpaca order/fill history into Rails
#
# This script:
# 1. Creates BrokerOrder records for all filled orders
# 2. Creates BrokerFill records for each order
# 3. Creates/closes PositionLot records with FIFO
# 4. Posts realized P&L to ledger
#
# Usage:
#   DRY_RUN=true bundle exec ruby script/backfill_all_alpaca_history.rb  # Preview
#   bundle exec ruby script/backfill_all_alpaca_history.rb               # Live run

require_relative '../config/environment'
require 'json'

class AlpacaHistoryBackfill
  ORDERS_FILE = '/tmp/alpaca_orders.json'

  # Agent assignment based on known positions and trading patterns
  # Order ID => agent_id (for orders we can identify)
  AGENT_MAPPING = {
    # Westin tickers
    'NVDA' => 'westin',
    'LRCX' => 'westin',
    'VRT' => 'westin',
    'GLW' => 'westin',
    'MU' => 'westin',
    'ARM' => 'westin',
    'FORM' => 'westin',
    'AAPL' => 'westin',

    # Dundas tickers
    'ASTS' => 'dundas',
    'TSLA' => 'dundas',
    'AMD' => 'dundas',
    'PLTR' => 'dundas',
    'TWST' => 'dundas',
    'AFRM' => 'dundas',
    'KRE' => 'dundas',
    'V' => 'dundas',

    # Gerrard tickers
    'USAR' => 'gerrard',
    'MP' => 'gerrard',
    'IWM' => 'gerrard',
    'GLD' => 'gerrard',
    'USO' => 'gerrard',
    'XLE' => 'gerrard',
    'XLI' => 'gerrard',
    'XLV' => 'gerrard',
    'AMZN' => 'gerrard',
    'PLD' => 'gerrard',
    'CCJ' => 'gerrard',
    'ORCL' => 'gerrard',
    'SPY' => 'gerrard',
    'F' => 'gerrard',
    'CNI' => 'gerrard',

    # Logan tickers
    'CMCSA' => 'logan',
    'VZ' => 'logan',
    'MO' => 'logan',
    'O' => 'logan',
    'PEP' => 'logan',
    'PRU' => 'logan',
    'UPS' => 'logan',
    'MRBK' => 'logan',
    'MCB' => 'logan'
  }.freeze

  def initialize(dry_run: false)
    @dry_run = dry_run
    @stats = {
      orders_processed: 0,
      orders_created: 0,
      orders_skipped: 0,
      fills_created: 0,
      fills_skipped: 0,
      lots_opened: 0,
      lots_closed: 0,
      realized_pnl: 0.0,
      errors: []
    }
    @position_lots = {} # agent_id:ticker => [lots]
    @agents_cache = {}
  end

  def run
    print_header
    load_orders
    load_existing_lots
    process_orders
    print_summary
  end

  private

  def print_header
    puts "=" * 80
    puts "Alpaca History Backfill"
    puts "Mode: #{@dry_run ? 'DRY RUN' : 'LIVE'}"
    puts "=" * 80
    puts
  end

  def load_orders
    unless File.exist?(ORDERS_FILE)
      puts "ERROR: Orders file not found at #{ORDERS_FILE}"
      puts "Run: curl -s ... > #{ORDERS_FILE}"
      exit 1
    end

    @orders = JSON.parse(File.read(ORDERS_FILE))
    @filled_orders = @orders.select { |o| o['status'] == 'filled' }
                           .sort_by { |o| o['filled_at'] }

    puts "Loaded #{@orders.size} total orders"
    puts "Filled orders: #{@filled_orders.size}"

    dates = @filled_orders.map { |o| o['filled_at'][0..9] }.uniq.sort
    puts "Date range: #{dates.first} to #{dates.last}"
    puts
  end

  def load_existing_lots
    # For accurate P&L tracking, we need to rebuild lot history
    # Check if we should clear bootstrap lots and rebuild from orders
    bootstrap_count = PositionLot.where(bootstrap_adjusted: true).count

    if bootstrap_count > 0 && !@dry_run
      puts "Found #{bootstrap_count} bootstrap lots"
      puts "These will be REPLACED with accurate lot history from Alpaca orders"
      puts "Clearing bootstrap lots..."
      PositionLot.where(bootstrap_adjusted: true).delete_all
      puts "Bootstrap lots cleared"
    elsif bootstrap_count > 0
      puts "Found #{bootstrap_count} bootstrap lots (would be replaced in live run)"
    end

    # Clear all existing data for clean rebuild
    if !@dry_run
      # Clear ledger entries linked to position lots
      ledger_count = LedgerTransaction.where(source_type: 'PositionLot').count
      if ledger_count > 0
        puts "Clearing #{ledger_count} P&L ledger transactions..."
        LedgerTransaction.where(source_type: 'PositionLot').destroy_all
      end

      # Clear position lots
      lot_count = PositionLot.count
      if lot_count > 0
        puts "Clearing #{lot_count} existing lots for rebuild..."
        PositionLot.delete_all
      end

      # Clear broker fills
      fill_count = BrokerFill.count
      if fill_count > 0
        puts "Clearing #{fill_count} existing broker fills for rebuild..."
        BrokerFill.delete_all
      end

      # Clear broker orders
      order_count = BrokerOrder.count
      if order_count > 0
        puts "Clearing #{order_count} existing broker orders for rebuild..."
        BrokerOrder.delete_all
      end

      puts "Database cleared for complete rebuild"
    end

    # Start with empty lots - will be built from orders
    @position_lots = {}
    puts "Starting fresh lot history from Alpaca orders"
    puts
  end

  def process_orders
    @filled_orders.each_with_index do |order, idx|
      process_order(order, idx + 1)
    end
  end

  def process_order(order, num)
    @stats[:orders_processed] += 1

    ticker = order['symbol']
    side = order['side']
    qty = order['filled_qty'].to_f
    price = order['filled_avg_price'].to_f
    filled_at = Time.parse(order['filled_at'])
    broker_order_id = order['id']

    # Check for existing order by broker_order_id
    if BrokerOrder.exists?(broker_order_id: broker_order_id)
      puts "[#{num}/#{@filled_orders.size}] SKIP: #{ticker} #{side} (order already exists)"
      @stats[:orders_skipped] += 1
      return
    end

    # Resolve agent
    agent = resolve_agent(ticker, order)
    unless agent
      msg = "No agent for #{ticker} order #{broker_order_id}"
      puts "[#{num}/#{@filled_orders.size}] ERROR: #{msg}"
      @stats[:errors] << msg
      return
    end

    if @dry_run
      puts "[#{num}/#{@filled_orders.size}] WOULD CREATE: #{agent.agent_id} #{ticker} #{side} #{qty.round(4)} @ $#{price.round(2)}"
      @stats[:orders_created] += 1
      @stats[:fills_created] += 1

      # Simulate lot operations
      if side == 'buy'
        @stats[:lots_opened] += 1
        add_simulated_lot(agent.agent_id, ticker, qty, price, filled_at)
      else
        pnl = simulate_lot_closing(agent.agent_id, ticker, qty, price)
        @stats[:lots_closed] += 1 if pnl
        @stats[:realized_pnl] += pnl if pnl
      end
    else
      create_order_and_fill(order, agent, ticker, side, qty, price, filled_at, broker_order_id, num)
    end
  rescue StandardError => e
    puts "[#{num}/#{@filled_orders.size}] EXCEPTION: #{e.message}"
    @stats[:errors] << "#{order['symbol']}: #{e.message}"
  end

  def resolve_agent(ticker, order)
    agent_id = AGENT_MAPPING[ticker]
    return nil unless agent_id

    @agents_cache[agent_id] ||= Agent.find_by(agent_id: agent_id)
  end

  def create_order_and_fill(order, agent, ticker, side, qty, price, filled_at, broker_order_id, num)
    ActiveRecord::Base.transaction do
      # Create BrokerOrder
      broker_order = BrokerOrder.create!(
        broker_order_id: broker_order_id,
        client_order_id: order['client_order_id'],
        agent: agent,
        ticker: ticker,
        side: side,
        order_type: order['order_type'] || 'market',
        time_in_force: order['time_in_force'] || 'day',
        qty_requested: order['qty']&.to_f,
        notional_requested: order['notional']&.to_f,
        status: 'filled',
        submitted_at: order['submitted_at'] ? Time.parse(order['submitted_at']) : filled_at,
        filled_at: filled_at,
        raw_response: order
      )

      # Create BrokerFill (broker_order_id is FK to broker_orders.id, not the UUID)
      fill_id = "#{filled_at.strftime('%Y%m%d%H%M%S%L')}::#{SecureRandom.uuid}"
      broker_fill = BrokerFill.create!(
        broker_fill_id: fill_id,
        broker_order_id: broker_order.id,  # FK to BrokerOrder record, not Alpaca UUID
        agent: agent,
        ticker: ticker,
        side: side,
        qty: qty,
        price: price,
        value: qty * price,
        executed_at: filled_at,
        fill_id_confidence: 'broker_verified',
        raw_fill: {
          id: fill_id,
          alpaca_order_id: broker_order_id,  # Store Alpaca UUID here
          symbol: ticker,
          side: side,
          qty: qty,
          price: price,
          transaction_time: filled_at.iso8601
        }
      )

      @stats[:orders_created] += 1
      @stats[:fills_created] += 1

      # Handle position lots
      if side == 'buy'
        create_lot(agent, ticker, qty, price, filled_at, broker_fill)
        @stats[:lots_opened] += 1
        puts "[#{num}/#{@filled_orders.size}] OK: #{agent.agent_id} BUY #{ticker} #{qty.round(4)} @ $#{price.round(2)} (lot opened)"
      else
        pnl = close_lots_fifo(agent, ticker, qty, price, filled_at, broker_fill)
        if pnl
          @stats[:lots_closed] += 1
          @stats[:realized_pnl] += pnl
          puts "[#{num}/#{@filled_orders.size}] OK: #{agent.agent_id} SELL #{ticker} #{qty.round(4)} @ $#{price.round(2)} (P&L: $#{pnl.round(2)})"
        else
          puts "[#{num}/#{@filled_orders.size}] OK: #{agent.agent_id} SELL #{ticker} #{qty.round(4)} @ $#{price.round(2)} (no lots to close)"
        end
      end
    end
  end

  def create_lot(agent, ticker, qty, price, filled_at, broker_fill)
    lot = PositionLot.create!(
      agent: agent,
      ticker: ticker,
      qty: qty,
      cost_basis_per_share: price,
      total_cost_basis: qty * price,
      opened_at: filled_at,
      open_source_type: 'BrokerFill',
      open_source_id: broker_fill.id
    )

    # Add to in-memory cache
    key = "#{agent.agent_id}:#{ticker}"
    @position_lots[key] ||= []
    @position_lots[key] << {
      id: lot.id,
      qty: qty,
      cost_basis: price,
      opened_at: filled_at
    }
  end

  def close_lots_fifo(agent, ticker, sell_qty, sell_price, filled_at, broker_fill)
    key = "#{agent.agent_id}:#{ticker}"
    lots = @position_lots[key] || []

    return nil if lots.empty?

    remaining = sell_qty
    total_pnl = 0.0

    while remaining > 0.0001 && lots.any?
      lot_data = lots.first
      lot = PositionLot.find(lot_data[:id])

      close_qty = [remaining, lot_data[:qty]].min
      pnl = (sell_price - lot_data[:cost_basis]) * close_qty
      total_pnl += pnl

      if close_qty >= lot_data[:qty] - 0.0001
        # Full close
        lot.update!(
          closed_at: filled_at,
          close_source_type: 'BrokerFill',
          close_source_id: broker_fill.id,
          realized_pnl: pnl
        )
        lots.shift
      else
        # Partial close - create new closed lot, reduce original
        PositionLot.create!(
          agent: agent,
          ticker: ticker,
          qty: close_qty,
          cost_basis_per_share: lot_data[:cost_basis],
          total_cost_basis: close_qty * lot_data[:cost_basis],
          opened_at: lot.opened_at,
          closed_at: filled_at,
          open_source_type: lot.open_source_type,
          open_source_id: lot.open_source_id,
          close_source_type: 'BrokerFill',
          close_source_id: broker_fill.id,
          realized_pnl: pnl
        )

        lot.update!(
          qty: lot.qty - close_qty,
          total_cost_basis: (lot.qty - close_qty) * lot_data[:cost_basis]
        )

        lot_data[:qty] -= close_qty
      end

      remaining -= close_qty

      # Post P&L to ledger
      post_realized_pnl(agent, ticker, pnl, filled_at, lot) if pnl.abs > 0.001
    end

    total_pnl
  end

  def post_realized_pnl(agent, ticker, pnl, booked_at, lot)
    return if pnl.abs < 0.01

    # Generate unique transaction ID
    ledger_txn_id = "TXN-#{booked_at.strftime('%Y%m%d%H%M%S%L')}-#{SecureRandom.hex(4)}"

    txn = LedgerTransaction.create!(
      ledger_txn_id: ledger_txn_id,
      source_type: 'PositionLot',
      source_id: lot.id,
      agent: agent,
      booked_at: booked_at,
      description: "Realized #{pnl >= 0 ? 'gain' : 'loss'}: #{ticker}"
    )

    # Debit realized P&L (positive = gain)
    LedgerEntry.create!(
      ledger_transaction: txn,
      account_code: "agent:#{agent.agent_id}:realized_pnl",
      amount: pnl,
      asset: 'USD',
      entry_seq: 1
    )

    # Credit cost basis adjustment (balancing entry)
    LedgerEntry.create!(
      ledger_transaction: txn,
      account_code: "agent:#{agent.agent_id}:cost_basis_adjustment",
      amount: -pnl,
      asset: 'USD',
      entry_seq: 2
    )
  end

  # Simulation methods for dry run
  def add_simulated_lot(agent_id, ticker, qty, price, opened_at)
    key = "#{agent_id}:#{ticker}"
    @position_lots[key] ||= []
    @position_lots[key] << {
      id: -1,
      qty: qty,
      cost_basis: price,
      opened_at: opened_at
    }
  end

  def simulate_lot_closing(agent_id, ticker, sell_qty, sell_price)
    key = "#{agent_id}:#{ticker}"
    lots = @position_lots[key] || []

    return nil if lots.empty?

    remaining = sell_qty
    total_pnl = 0.0

    while remaining > 0.0001 && lots.any?
      lot_data = lots.first
      close_qty = [remaining, lot_data[:qty]].min
      pnl = (sell_price - lot_data[:cost_basis]) * close_qty
      total_pnl += pnl

      if close_qty >= lot_data[:qty] - 0.0001
        lots.shift
      else
        lot_data[:qty] -= close_qty
      end

      remaining -= close_qty
    end

    total_pnl
  end

  def print_summary
    puts
    puts "=" * 80
    puts "BACKFILL SUMMARY"
    puts "=" * 80
    puts "Orders processed:  #{@stats[:orders_processed]}"
    puts "Orders created:    #{@stats[:orders_created]}"
    puts "Orders skipped:    #{@stats[:orders_skipped]} (already exist)"
    puts "Fills created:     #{@stats[:fills_created]}"
    puts "Lots opened:       #{@stats[:lots_opened]}"
    puts "Lots closed:       #{@stats[:lots_closed]}"
    puts "Realized P&L:      $#{@stats[:realized_pnl].round(2)}"

    if @stats[:errors].any?
      puts
      puts "ERRORS (#{@stats[:errors].size}):"
      @stats[:errors].each { |e| puts "  - #{e}" }
    end

    puts "=" * 80
  end
end

# Run
dry_run = ENV['DRY_RUN'] == 'true'
backfill = AlpacaHistoryBackfill.new(dry_run: dry_run)
backfill.run
