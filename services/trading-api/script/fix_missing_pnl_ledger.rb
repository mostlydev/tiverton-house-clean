#!/usr/bin/env ruby
# frozen_string_literal: true

# Fix missing P&L ledger entries
require_relative '../config/environment'
require 'securerandom'

count = 0
errors = []

PositionLot.where.not(closed_at: nil).find_each do |lot|
  next unless lot.realized_pnl
  next if lot.realized_pnl.abs < 0.01
  next if LedgerTransaction.exists?(source_type: 'PositionLot', source_id: lot.id)

  begin
    ActiveRecord::Base.transaction do
      ledger_txn_id = "TXN-#{lot.closed_at.strftime('%Y%m%d%H%M%S%L')}-#{SecureRandom.hex(4)}"

      # Create transaction
      txn = LedgerTransaction.new(
        ledger_txn_id: ledger_txn_id,
        source_type: 'PositionLot',
        source_id: lot.id,
        agent: lot.agent,
        booked_at: lot.closed_at,
        description: "Realized #{lot.realized_pnl >= 0 ? 'gain' : 'loss'}: #{lot.ticker}"
      )
      txn.save!(validate: false)

      # Create both entries at once to pass balance validation
      pnl = lot.realized_pnl
      agent_id = lot.agent.agent_id

      sql = "INSERT INTO ledger_entries (ledger_transaction_id, entry_seq, account_code, amount, asset, created_at, updated_at) VALUES (#{txn.id}, 1, 'agent:#{agent_id}:realized_pnl', #{pnl}, 'USD', NOW(), NOW()), (#{txn.id}, 2, 'agent:#{agent_id}:cost_basis_adjustment', #{-pnl}, 'USD', NOW(), NOW())"
      ActiveRecord::Base.connection.execute(sql)

      puts "OK: #{lot.ticker} $#{pnl.round(2)} (#{agent_id})"
      count += 1
    end
  rescue StandardError => e
    errors << "#{lot.ticker}: #{e.message}"
  end
end

puts
puts "Posted #{count} entries"
if errors.any?
  puts "Errors: #{errors.size}"
  errors.each { |e| puts "  - #{e}" }
end
