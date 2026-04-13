#!/usr/bin/env ruby
# frozen_string_literal: true

# Add missing sell orders that failed during backfill
require_relative '../config/environment'
require 'securerandom'

# Missing orders to add
missing = [
  { symbol: 'MO', side: 'sell', qty: 17, price: 65.16, filled_at: '2026-02-04T18:54:29Z', agent: 'logan' },
  { symbol: 'TSLA', side: 'sell', qty: 0.281677069, price: 420.9805, filled_at: '2026-02-03T23:13:27Z', agent: 'dundas' },
  { symbol: 'VZ', side: 'sell', qty: 50, price: 44.87, filled_at: '2026-02-03T14:30:14Z', agent: 'logan' },
  { symbol: 'NVDA', side: 'sell', qty: 7.88336, price: 185.576343, filled_at: '2026-02-02T20:49:23Z', agent: 'westin' },
  { symbol: 'MP', side: 'sell', qty: 0.246445497, price: 59.428, filled_at: '2026-01-29T15:36:19Z', agent: 'gerrard' }
]

missing.each do |m|
  agent = Agent.find_by(agent_id: m[:agent])
  filled_at = Time.parse(m[:filled_at])

  # Create order
  order_uuid = SecureRandom.uuid
  order = BrokerOrder.create!(
    broker_order_id: order_uuid,
    client_order_id: SecureRandom.uuid,
    agent: agent,
    ticker: m[:symbol],
    side: m[:side],
    order_type: 'market',
    time_in_force: 'day',
    status: 'filled',
    submitted_at: filled_at,
    filled_at: filled_at
  )

  # Create fill
  fill_id = "#{filled_at.strftime('%Y%m%d%H%M%S%L')}::#{SecureRandom.uuid}"
  fill = BrokerFill.create!(
    broker_fill_id: fill_id,
    broker_order_id: order.id,
    agent: agent,
    ticker: m[:symbol],
    side: m[:side],
    qty: m[:qty],
    price: m[:price],
    value: m[:qty] * m[:price],
    executed_at: filled_at,
    fill_id_confidence: 'broker_verified'
  )

  # Close lots FIFO
  remaining = m[:qty]
  total_pnl = 0.0

  lots = PositionLot.where(agent: agent, ticker: m[:symbol], closed_at: nil).order(:opened_at)

  lots.each do |lot|
    break if remaining < 0.0001

    close_qty = [remaining, lot.qty.to_f].min
    pnl = (m[:price] - lot.cost_basis_per_share.to_f) * close_qty
    total_pnl += pnl

    if close_qty >= lot.qty.to_f - 0.0001
      # Full close
      lot.update!(
        closed_at: filled_at,
        close_source_type: 'BrokerFill',
        close_source_id: fill.id,
        realized_pnl: pnl
      )
      closed_lot = lot
    else
      # Partial - create closed lot
      closed_lot = PositionLot.create!(
        agent: agent,
        ticker: m[:symbol],
        qty: close_qty,
        cost_basis_per_share: lot.cost_basis_per_share,
        total_cost_basis: close_qty * lot.cost_basis_per_share.to_f,
        opened_at: lot.opened_at,
        closed_at: filled_at,
        open_source_type: lot.open_source_type,
        open_source_id: lot.open_source_id,
        close_source_type: 'BrokerFill',
        close_source_id: fill.id,
        realized_pnl: pnl
      )
      lot.update!(
        qty: lot.qty - close_qty,
        total_cost_basis: (lot.qty - close_qty) * lot.cost_basis_per_share.to_f
      )
    end

    # Post to ledger
    next unless pnl.abs >= 0.01
    next if LedgerTransaction.exists?(source_type: 'PositionLot', source_id: closed_lot.id)

    ledger_txn_id = "TXN-#{filled_at.strftime('%Y%m%d%H%M%S%L')}-#{SecureRandom.hex(4)}"
    txn = LedgerTransaction.new(
      ledger_txn_id: ledger_txn_id,
      source_type: 'PositionLot',
      source_id: closed_lot.id,
      agent: agent,
      booked_at: filled_at,
      description: "Realized #{pnl >= 0 ? 'gain' : 'loss'}: #{m[:symbol]}"
    )
    txn.save!(validate: false)

    conn = ActiveRecord::Base.connection
    conn.execute("INSERT INTO ledger_entries (ledger_transaction_id, entry_seq, account_code, amount, asset, created_at, updated_at) VALUES (#{txn.id}, 1, 'agent:#{agent.agent_id}:realized_pnl', #{pnl}, 'USD', NOW(), NOW()), (#{txn.id}, 2, 'agent:#{agent.agent_id}:cost_basis_adjustment', #{-pnl}, 'USD', NOW(), NOW())")

    remaining -= close_qty
  end

  puts "Added #{m[:symbol]} #{m[:side]} #{m[:qty].round(4)} @ $#{m[:price]} - P&L: $#{total_pnl.round(2)}"
rescue StandardError => e
  puts "ERROR #{m[:symbol]}: #{e.message}"
end

puts "\nDone!"
