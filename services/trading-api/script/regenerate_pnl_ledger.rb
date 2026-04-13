#!/usr/bin/env ruby
# frozen_string_literal: true

# Regenerate all P&L ledger entries from position lots
require_relative '../config/environment'
require 'securerandom'

puts "=== Regenerating P&L Ledger Entries ==="

# Clear existing P&L ledger entries
old_count = LedgerTransaction.where(source_type: 'PositionLot').count
puts "Clearing #{old_count} existing P&L transactions..."
LedgerTransaction.where(source_type: 'PositionLot').destroy_all

# Regenerate from closed lots
count = 0
errors = []

PositionLot.where.not(closed_at: nil).order(:closed_at).find_each do |lot|
  next unless lot.realized_pnl
  next if lot.realized_pnl.abs < 0.01

  begin
    ledger_txn_id = "TXN-#{lot.closed_at.strftime('%Y%m%d%H%M%S%L')}-#{SecureRandom.hex(4)}"

    txn = LedgerTransaction.new(
      ledger_txn_id: ledger_txn_id,
      source_type: 'PositionLot',
      source_id: lot.id,
      agent: lot.agent,
      booked_at: lot.closed_at,
      description: "Realized #{lot.realized_pnl >= 0 ? 'gain' : 'loss'}: #{lot.ticker}"
    )
    txn.save!(validate: false)

    pnl = lot.realized_pnl.to_f
    agent_id = lot.agent.agent_id

    conn = ActiveRecord::Base.connection
    conn.execute("INSERT INTO ledger_entries (ledger_transaction_id, entry_seq, account_code, amount, asset, created_at, updated_at) VALUES (#{txn.id}, 1, 'agent:#{agent_id}:realized_pnl', #{pnl}, 'USD', NOW(), NOW()), (#{txn.id}, 2, 'agent:#{agent_id}:cost_basis_adjustment', #{-pnl}, 'USD', NOW(), NOW())")

    count += 1
  rescue StandardError => e
    errors << "Lot #{lot.id} #{lot.ticker}: #{e.message}"
  end
end

puts "Created #{count} ledger transactions"

if errors.any?
  puts "\nErrors:"
  errors.each { |e| puts "  - #{e}" }
end

# Verify
puts "\n=== Verification ==="
total_ledger = LedgerEntry.where("account_code LIKE ?", '%:realized_pnl').sum(:amount).to_f
total_lots = PositionLot.where.not(closed_at: nil).sum(:realized_pnl).to_f
diff = (total_ledger - total_lots).abs

puts "Ledger Total: $#{total_ledger.round(2)}"
puts "Lots Total:   $#{total_lots.round(2)}"
puts "Difference:   $#{diff.round(2)} #{diff < 0.1 ? '✓ RECONCILED' : '⚠ MISMATCH'}"
