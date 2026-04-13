# frozen_string_literal: true

# Usage:
#   bin/rails runner script/backfill_position_lots_from_fills.rb -- [--apply]
# Default dry-run.

require 'optparse'

class BackfillPositionLotsFromFills
  Result = Struct.new(:fills_scanned, :fills_backfilled, :lots_created, :lots_closed, :skipped_with_lots, :oversold_skipped, keyword_init: true)

  def run!(apply: false)
    result = Result.new(fills_scanned: 0, fills_backfilled: 0, lots_created: 0, lots_closed: 0, skipped_with_lots: 0, oversold_skipped: 0)

    ActiveRecord::Base.transaction do
      BrokerFill.includes(:agent).find_each do |fill|
        result.fills_scanned += 1
        next unless fill.agent

        if PositionLot.where(open_source_type: 'BrokerFill', open_source_id: fill.id).exists? ||
           PositionLot.where(close_source_type: 'BrokerFill', close_source_id: fill.id).exists?
          result.skipped_with_lots += 1
          next
        end

        result.fills_backfilled += 1
        next unless apply

        if fill.side == 'buy'
          PositionLot.create!(
            agent: fill.agent,
            ticker: fill.ticker,
            qty: fill.qty,
            cost_basis_per_share: fill.price,
            total_cost_basis: fill.qty * fill.price,
            opened_at: fill.executed_at,
            open_source_type: 'BrokerFill',
            open_source_id: fill.id
          )
          result.lots_created += 1
        else
          # Close existing lots FIFO
          remaining_qty = fill.qty
          open_lots = PositionLot
                      .where(agent: fill.agent, ticker: fill.ticker, closed_at: nil)
                      .where('qty > 0')
                      .order(:opened_at)

          open_lots.each do |lot|
            break if remaining_qty <= 0

            qty_to_close = [lot.qty, remaining_qty].min
            realized_pnl = (fill.price - lot.cost_basis_per_share) * qty_to_close

            if qty_to_close >= lot.qty
              lot.update!(
                closed_at: fill.executed_at,
                close_source_type: 'BrokerFill',
                close_source_id: fill.id,
                realized_pnl: realized_pnl
              )
            else
              new_qty = lot.qty - qty_to_close
              lot.update!(qty: new_qty, total_cost_basis: lot.cost_basis_per_share * new_qty)

              PositionLot.create!(
                agent: fill.agent,
                ticker: lot.ticker,
                qty: qty_to_close,
                cost_basis_per_share: lot.cost_basis_per_share,
                total_cost_basis: lot.cost_basis_per_share * qty_to_close,
                opened_at: lot.opened_at,
                closed_at: fill.executed_at,
                open_source_type: lot.open_source_type,
                open_source_id: lot.open_source_id,
                close_source_type: 'BrokerFill',
                close_source_id: fill.id,
                realized_pnl: realized_pnl
              )
            end

            result.lots_closed += 1
            remaining_qty -= qty_to_close
          end

          if remaining_qty > 0
            # Oversold: negative lots are not allowed by model validation.
            # Skip and track for manual review.
            result.oversold_skipped += 1
          end
        end
      end

      raise ActiveRecord::Rollback unless apply
    end

    result
  end
end

options = { apply: false }
OptionParser.new do |opts|
  opts.banner = 'Usage: bin/rails runner script/backfill_position_lots_from_fills.rb -- [--apply]'
  opts.on('--apply', 'Persist changes (default dry-run)') { options[:apply] = true }
end.parse!(ARGV)

result = BackfillPositionLotsFromFills.new.run!(apply: options[:apply])
puts result.to_h.to_json
