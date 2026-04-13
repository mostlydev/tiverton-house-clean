# frozen_string_literal: true

# Usage:
#   bin/rails runner script/check_alpaca_consistency.rb -- [--positions-only] [--cash-only] [--qty-tolerance=0.0001] [--cash-tolerance=5] [--json]
#
# Exits with code:
#   0 = OK
#   2 = FAIL (mismatch)
#   1 = ERROR

require "optparse"
require "json"

options = {
  positions: true,
  cash: true,
  qty_tolerance: 0.0001,
  cash_tolerance: 5.0,
  json: false
}

OptionParser.new do |opts|
  opts.banner = "Usage: bin/rails runner script/check_alpaca_consistency.rb -- [options]"
  opts.on("--positions-only", "Only check positions") { options[:cash] = false }
  opts.on("--cash-only", "Only check cash") { options[:positions] = false }
  opts.on("--qty-tolerance=VAL", Float, "Position qty tolerance (default 0.0001)") { |v| options[:qty_tolerance] = v }
  opts.on("--cash-tolerance=VAL", Float, "Cash tolerance in USD (default 5)") { |v| options[:cash_tolerance] = v }
  opts.on("--json", "Output JSON only") { options[:json] = true }
end.parse!(ARGV)

def normalize_symbol(symbol)
  sym = symbol.to_s.upcase
  return sym if sym.include?("/")
  return "#{sym[0..-4]}/USD" if sym.end_with?("USD") && sym.length > 3

  sym
end

result = {
  ok: true,
  positions: nil,
  cash: nil
}

broker = Alpaca::BrokerService.new

if options[:positions]
  alpaca_positions = broker.get_positions
  alpaca_map = Hash.new(0.0)
  alpaca_positions.each do |pos|
    ticker = normalize_symbol(pos[:ticker])
    alpaca_map[ticker] += pos[:qty].to_f
  end

  ledger_map = Hash.new(0.0)
  PositionLot.where(closed_at: nil).group(:ticker).sum(:qty).each do |ticker, qty|
    ledger_map[normalize_symbol(ticker)] += qty.to_f
  end

  all_tickers = (alpaca_map.keys + ledger_map.keys).uniq
  mismatches = []

  all_tickers.each do |ticker|
    alpaca_qty = alpaca_map[ticker].to_f
    ledger_qty = ledger_map[ticker].to_f

    next if alpaca_qty.abs <= options[:qty_tolerance] && ledger_qty.abs <= options[:qty_tolerance]

    diff = (ledger_qty - alpaca_qty).abs
    if diff > options[:qty_tolerance]
      mismatches << {
        ticker: ticker,
        alpaca_qty: alpaca_qty,
        ledger_qty: ledger_qty,
        diff: (ledger_qty - alpaca_qty)
      }
    end
  end

  positions_ok = mismatches.empty?
  result[:positions] = {
    ok: positions_ok,
    alpaca_count: alpaca_map.keys.count,
    ledger_count: ledger_map.keys.count,
    mismatches: mismatches
  }
  result[:ok] &&= positions_ok
end

if options[:cash]
  account = broker.get_account
  if account[:success] == false
    result[:cash] = { ok: false, error: account[:error] || "account fetch failed" }
    result[:ok] = false
  else
    projection = Ledger::ProjectionService.new
    ledger_cash = projection.all_wallets.sum { |w| w[:cash].to_f }
    alpaca_cash = account[:cash].to_f
    diff = ledger_cash - alpaca_cash
    cash_ok = diff.abs <= options[:cash_tolerance]

    result[:cash] = {
      ok: cash_ok,
      ledger_cash: ledger_cash,
      alpaca_cash: alpaca_cash,
      diff: diff
    }
    result[:ok] &&= cash_ok
  end
end

if options[:json]
  puts JSON.pretty_generate(result)
else
  puts "Alpaca consistency check: #{result[:ok] ? 'OK' : 'FAIL'}"
  if result[:positions]
    puts "  Positions: #{result[:positions][:ok] ? 'OK' : 'FAIL'} (alpaca=#{result[:positions][:alpaca_count]}, ledger=#{result[:positions][:ledger_count]})"
    if result[:positions][:mismatches].any?
      result[:positions][:mismatches].each do |m|
        puts "    #{m[:ticker]}: alpaca=#{m[:alpaca_qty]} ledger=#{m[:ledger_qty]} diff=#{m[:diff]}"
      end
    end
  end
  if result[:cash]
    if result[:cash][:ok]
      puts "  Cash: OK (ledger=#{format('%.2f', result[:cash][:ledger_cash])} alpaca=#{format('%.2f', result[:cash][:alpaca_cash])} diff=#{format('%.2f', result[:cash][:diff])})"
    else
      puts "  Cash: FAIL (#{result[:cash][:error] || 'diff too large'})"
    end
  end
end

exit(result[:ok] ? 0 : 2)
