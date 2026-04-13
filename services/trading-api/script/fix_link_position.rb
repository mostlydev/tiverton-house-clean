#!/usr/bin/env ruby
# frozen_string_literal: true

# Fix LINK/USD position mismatch
# - Quantity: 27.04798702 (ledger) vs 26.980367055 (Alpaca)
# - Create ADJUSTMENT transaction for the diff

puts "=== LINK/USD Position Fix ==="
app_root = File.expand_path("..", __dir__)

lot = PositionLot.find_by(ticker: "LINK/USD", closed_at: nil)
if lot.nil?
  puts "ERROR: No open LINK/USD position lot found"
  exit 1
end

puts "Current lot [#{lot.id}]:"
puts "  ticker: #{lot.ticker}"
puts "  qty: #{lot.qty}"
puts "  agent_id: #{lot.agent_id}"

ALPACA_QTY = 26.980367055
LEDGER_QTY = 27.04798702
DIFF = ALPACA_QTY - LEDGER_QTY

puts "\nAdjustment needed:"
puts "  Alpaca qty: #{ALPACA_QTY}"
puts "  Ledger qty: #{LEDGER_QTY}"
puts "  Diff: #{DIFF} shares"

puts "\nCreating ADJUSTMENT ledger transaction..."

ActiveRecord::Base.transaction do
  # Create adjustment transaction
  tx = LedgerTransaction.create!(
    ledger_txn_id: "TXN-#{Time.now.strftime('%Y%m%d%H%M%S%3N')}-adjustment",
    source_type: "Reconciliation",
    source_id: nil,
    agent_id: lot.agent_id,
    asset: "LINK/USD",
    booked_at: Time.now,
    description: "Reconciliation adjustment: align with Alpaca qty #{ALPACA_QTY} (was #{LEDGER_QTY})"
  )

  # Update position lot
  lot.update!(qty: ALPACA_QTY)

  puts "✓ Created transaction [#{tx.id}]: #{tx.ledger_txn_id}"
  puts "✓ Updated lot [#{lot.id}] qty to #{lot.qty}"
end

puts "\nVerifying..."
system("bin/rails", "runner", "script/check_alpaca_consistency.rb", "--", "--positions-only", chdir: app_root)
