# frozen_string_literal: true

# Usage:
#   bin/rails runner script/recompute_trade_fills_from_broker_fills.rb -- [--apply]
# Default is dry-run.

require 'optparse'

class RecomputeTradeFills
  Result = Struct.new(
    :trades_scanned,
    :trades_updated,
    :skipped_no_fills,
    keyword_init: true
  )

  def run!(apply: false)
    result = Result.new(
      trades_scanned: 0,
      trades_updated: 0,
      skipped_no_fills: 0
    )

    Trade.find_each do |trade|
      fills = BrokerFill.where(trade_id: trade.id)
      if fills.empty?
        result.skipped_no_fills += 1
        next
      end

      result.trades_scanned += 1

      sum_qty = fills.sum(:qty).to_f
      sum_value = fills.sum("qty * price").to_f
      vwap = sum_qty.positive? ? (sum_value / sum_qty) : 0

      last_exec = fills.maximum(:executed_at)
      first_exec = fills.minimum(:executed_at)

      changes = {}
      changes[:qty_filled] = sum_qty if trade.qty_filled.to_f != sum_qty
      changes[:avg_fill_price] = vwap if trade.avg_fill_price.to_f != vwap
      changes[:filled_value] = sum_value if trade.filled_value.to_f != sum_value
      changes[:execution_started_at] = first_exec if trade.execution_started_at.nil? && first_exec
      changes[:execution_completed_at] = last_exec if trade.execution_completed_at.nil? && last_exec

      next if changes.empty?

      result.trades_updated += 1
      trade.update_columns(changes) if apply
    end

    result
  end
end

options = { apply: false }
OptionParser.new do |opts|
  opts.banner = 'Usage: bin/rails runner script/recompute_trade_fills_from_broker_fills.rb -- [--apply]'
  opts.on('--apply', 'Persist changes (default dry-run)') { options[:apply] = true }
end.parse!(ARGV)

result = RecomputeTradeFills.new.run!(apply: options[:apply])
puts result.to_h.to_json
