# frozen_string_literal: true

# Usage:
#   bin/rails runner script/align_ledger_to_alpaca.rb -- [--apply] [--positions] [--cash] [--qty-tolerance=0.0001] [--cash-tolerance=5]
# Default: positions + cash, dry-run.

require "optparse"
require "json"

options = {
  apply: false,
  positions: true,
  cash: true,
  qty_tolerance: 0.0001,
  cash_tolerance: 5.0
}

OptionParser.new do |opts|
  opts.banner = "Usage: bin/rails runner script/align_ledger_to_alpaca.rb -- [options]"
  opts.on("--apply", "Persist changes (default dry-run)") { options[:apply] = true }
  opts.on("--positions", "Align positions (default on)") { options[:positions] = true }
  opts.on("--cash", "Align cash (default on)") { options[:cash] = true }
  opts.on("--qty-tolerance=VAL", Float, "Position qty tolerance (default 0.0001)") { |v| options[:qty_tolerance] = v }
  opts.on("--cash-tolerance=VAL", Float, "Cash tolerance in USD (default 5)") { |v| options[:cash_tolerance] = v }
end.parse!(ARGV)

def normalize_symbol(symbol)
  sym = symbol.to_s.upcase
  return sym if sym.include?("/")
  return "#{sym[0..-4]}/USD" if sym.end_with?("USD") && sym.length > 3

  sym
end

def price_for(ticker, fallback: 1.0)
  sample = PriceSample.where(ticker: ticker).order(sampled_at: :desc).first
  return sample.price.to_f if sample&.price.to_f.positive?

  fallback
end

broker = Alpaca::BrokerService.new
system_agent = Agent.find_by(agent_id: "system")

result = {
  apply: options[:apply],
  positions: nil,
  cash: nil,
  ok: true
}

if options[:positions]
  alpaca_positions = broker.get_positions
  alpaca_map = Hash.new(0.0)
  alpaca_meta = {}
  alpaca_positions.each do |pos|
    ticker = normalize_symbol(pos[:ticker])
    alpaca_map[ticker] += pos[:qty].to_f
    alpaca_meta[ticker] = pos
  end

  ledger_map = Hash.new(0.0)
  PositionLot.where(closed_at: nil).group(:ticker).sum(:qty).each do |ticker, qty|
    ledger_map[normalize_symbol(ticker)] += qty.to_f
  end

  adjustments = []

  ActiveRecord::Base.transaction do
    (alpaca_map.keys + ledger_map.keys).uniq.each do |ticker|
      alpaca_qty = alpaca_map[ticker].to_f
      ledger_qty = ledger_map[ticker].to_f
      diff = alpaca_qty - ledger_qty

      next if diff.abs <= options[:qty_tolerance]

      if diff > 0
        # Missing in ledger: add lot(s) to system agent
        pos = alpaca_meta[ticker] || {}
        basis = pos[:avg_entry_price].to_f
        basis = pos[:current_price].to_f if basis <= 0
        basis = price_for(ticker, fallback: 1.0) if basis <= 0

        adjustments << { ticker: ticker, action: "add_lot", qty: diff, cost_basis: basis }
        if options[:apply]
          PositionLot.create!(
            agent: system_agent,
            ticker: ticker,
            qty: diff,
            cost_basis_per_share: basis,
            total_cost_basis: diff * basis,
            opened_at: Time.current,
            open_source_type: "AlpacaSync",
            open_source_id: 0,
            bootstrap_adjusted: true
          )
        end
      else
        # Ledger over-reported: close lots (LIFO) for the excess
        remaining = diff.abs
        lots = PositionLot.where(closed_at: nil, ticker: ticker).order(opened_at: :desc, id: :desc).to_a
        lots.sort_by! do |lot|
          [
            lot.agent&.agent_id == "system" ? 0 : 1,
            -(lot.opened_at&.to_i || 0),
            -lot.id.to_i
          ]
        end
        lots.each do |lot|
          break if remaining <= 0

          close_qty = [lot.qty, remaining].min
          adjustments << { ticker: ticker, action: "close_lot", qty: close_qty, lot_id: lot.id }

          if options[:apply]
            if close_qty >= lot.qty
              lot.update!(
                closed_at: Time.current,
                close_source_type: "AlpacaSync",
                close_source_id: nil,
                realized_pnl: nil,
                bootstrap_adjusted: true
              )
            else
              new_qty = lot.qty - close_qty
              lot.update!(qty: new_qty, total_cost_basis: lot.cost_basis_per_share * new_qty, bootstrap_adjusted: true)

              PositionLot.create!(
                agent: lot.agent,
                ticker: lot.ticker,
                qty: close_qty,
                cost_basis_per_share: lot.cost_basis_per_share,
                total_cost_basis: lot.cost_basis_per_share * close_qty,
                opened_at: lot.opened_at,
                closed_at: Time.current,
                open_source_type: lot.open_source_type,
                open_source_id: lot.open_source_id,
                close_source_type: "AlpacaSync",
                close_source_id: nil,
                realized_pnl: nil,
                bootstrap_adjusted: true
              )
            end
          end

          remaining -= close_qty
        end
      end
    end

    raise ActiveRecord::Rollback unless options[:apply]
  end

  result[:positions] = {
    ok: adjustments.empty?,
    adjustments: adjustments
  }
  result[:ok] &&= adjustments.empty?
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
    diff = alpaca_cash - ledger_cash

    cash_ok = diff.abs <= options[:cash_tolerance]
    if !cash_ok && options[:apply]
      # Ensure unique source_id to satisfy ledger_transactions unique index.
      sync_id = (Time.current.to_f * 1000).to_i
      while LedgerTransaction.exists?(source_type: "AlpacaSync", source_id: sync_id)
        sync_id += 1
      end

      posting = Ledger::PostingService.new(
        source_type: "AlpacaSync",
        source_id: sync_id,
        agent: "system",
        asset: "USD",
        booked_at: Time.current,
        description: "Align cash to Alpaca (delta #{diff.round(2)})",
        bootstrap_adjusted: true
      )

      posting.add_entry(account_code: "agent:system:cash", amount: diff, asset: "USD")
      posting.add_entry(account_code: "alpaca:sync:cash", amount: -diff, asset: "USD")
      posting.post!
    end

    result[:cash] = {
      ok: cash_ok,
      ledger_cash: ledger_cash,
      alpaca_cash: alpaca_cash,
      diff: diff,
      adjusted: (!cash_ok && options[:apply])
    }
    result[:ok] &&= cash_ok
  end
end

puts JSON.pretty_generate(result)
exit(result[:ok] ? 0 : 2)
