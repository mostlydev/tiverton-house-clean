# frozen_string_literal: true

# Usage:
#   bin/rails runner script/rebuild_lots_and_ledger_from_fills.rb -- [--apply]
# Default is dry-run.

require "optparse"

class RebuildLotsAndLedgerFromFills
  Result = Struct.new(
    :derived_fills_removed,
    :broker_fill_txns_removed,
    :position_lot_txns_removed,
    :ledger_entries_removed,
    :lots_removed,
    :lots_created,
    :lots_closed,
    :pnl_txns_created,
    :broker_fill_txns_created,
    :oversold_events,
    keyword_init: true
  )

  def run!(apply: false)
    result = Result.new(
      derived_fills_removed: 0,
      broker_fill_txns_removed: 0,
      position_lot_txns_removed: 0,
      ledger_entries_removed: 0,
      lots_removed: 0,
      lots_created: 0,
      lots_closed: 0,
      pnl_txns_created: 0,
      broker_fill_txns_created: 0,
      oversold_events: 0
    )

    ActiveRecord::Base.transaction do
      if apply
        result.derived_fills_removed = remove_derived_fills!
        remove_ledger_for_source!("BrokerFill", result)
        remove_ledger_for_source!("PositionLot", result)
        result.lots_removed = PositionLot.count
        PositionLot.delete_all
      end

      BrokerFill.order(:executed_at, :id).find_each do |fill|
        next unless apply

        post_broker_fill_to_ledger!(fill)
        result.broker_fill_txns_created += 1

        if fill.side == "buy"
          create_open_lot!(fill)
          result.lots_created += 1
        else
          closed = close_lots_fifo!(fill, result)
          result.lots_closed += closed
        end
      end

      raise ActiveRecord::Rollback unless apply
    end

    result
  end

  private

  def remove_derived_fills!
    order_ids = BrokerFill.group(:broker_order_id)
                          .having("SUM(CASE WHEN fill_id_confidence='broker_verified' THEN 1 ELSE 0 END) > 0")
                          .pluck(:broker_order_id)

    derived = BrokerFill.where(broker_order_id: order_ids)
                        .where.not(fill_id_confidence: "broker_verified")

    count = derived.count
    derived.delete_all
    count
  end

  def remove_ledger_for_source!(source_type, result)
    txns = LedgerTransaction.where(source_type: source_type)
    txn_ids = txns.pluck(:id)
    return if txn_ids.empty?

    LedgerEntry.where(ledger_transaction_id: txn_ids).delete_all.tap do |count|
      result.ledger_entries_removed += count
    end
    LedgerAdjustment.where(ledger_transaction_id: txn_ids).delete_all
    txns.delete_all

    if source_type == "BrokerFill"
      result.broker_fill_txns_removed = txn_ids.length
    elsif source_type == "PositionLot"
      result.position_lot_txns_removed = txn_ids.length
    end
  end

  def post_broker_fill_to_ledger!(fill)
    posting = Ledger::PostingService.new(
      source_type: "BrokerFill",
      source_id: fill.id,
      agent: fill.agent.agent_id,
      asset: fill.ticker,
      booked_at: fill.executed_at,
      description: "REBUILD #{fill.side.upcase} #{fill.qty} #{fill.ticker} @ #{fill.price}"
    )

    cash_account = "agent:#{fill.agent.agent_id}:cash"
    position_account = "agent:#{fill.agent.agent_id}:#{fill.ticker}"

    if fill.side == "buy"
      posting.add_entry(account_code: position_account, amount: fill.value, asset: fill.ticker)
      posting.add_entry(account_code: cash_account, amount: -fill.value, asset: "USD")
    else
      posting.add_entry(account_code: cash_account, amount: fill.value, asset: "USD")
      posting.add_entry(account_code: position_account, amount: -fill.value, asset: fill.ticker)
    end

    posting.post!
  end

  def create_open_lot!(fill)
    PositionLot.create!(
      agent: fill.agent,
      ticker: fill.ticker,
      qty: fill.qty,
      cost_basis_per_share: fill.price,
      total_cost_basis: fill.value,
      opened_at: fill.executed_at,
      open_source_type: "BrokerFill",
      open_source_id: fill.id,
      bootstrap_adjusted: true
    )
  end

  def close_lots_fifo!(fill, result)
    remaining_qty = fill.qty
    closed_count = 0

    open_lots = PositionLot
                .where(agent: fill.agent, ticker: fill.ticker, closed_at: nil)
                .where("qty > 0")
                .order(:opened_at, :id)

    open_lots.each do |lot|
      break if remaining_qty <= 0

      qty_to_close = [lot.qty, remaining_qty].min
      realized_pnl = (fill.price - lot.cost_basis_per_share) * qty_to_close

      closed_lot = nil
      if qty_to_close >= lot.qty
        lot.update!(
          closed_at: fill.executed_at,
          close_source_type: "BrokerFill",
          close_source_id: fill.id,
          realized_pnl: realized_pnl,
          bootstrap_adjusted: true
        )
        closed_lot = lot
      else
        new_qty = lot.qty - qty_to_close
        lot.update!(qty: new_qty, total_cost_basis: lot.cost_basis_per_share * new_qty, bootstrap_adjusted: true)

        closed_lot = PositionLot.create!(
          agent: fill.agent,
          ticker: lot.ticker,
          qty: qty_to_close,
          cost_basis_per_share: lot.cost_basis_per_share,
          total_cost_basis: lot.cost_basis_per_share * qty_to_close,
          opened_at: lot.opened_at,
          closed_at: fill.executed_at,
          open_source_type: lot.open_source_type,
          open_source_id: lot.open_source_id,
          close_source_type: "BrokerFill",
          close_source_id: fill.id,
          realized_pnl: realized_pnl,
          bootstrap_adjusted: true
        )
      end

      post_realized_pnl!(fill.agent, closed_lot, realized_pnl) if realized_pnl.abs >= 0.0001
      result.pnl_txns_created += 1 if realized_pnl.abs >= 0.0001

      remaining_qty -= qty_to_close
      closed_count += 1
    end

    if remaining_qty > 0
      result.oversold_events += 1

      # Create synthetic closed lot to record the unmatched sell (P&L = 0)
      PositionLot.create!(
        agent: fill.agent,
        ticker: fill.ticker,
        qty: remaining_qty,
        cost_basis_per_share: fill.price,
        total_cost_basis: remaining_qty * fill.price,
        opened_at: fill.executed_at,
        closed_at: fill.executed_at,
        open_source_type: "Bootstrap",
        close_source_type: "BrokerFill",
        close_source_id: fill.id,
        realized_pnl: 0,
        bootstrap_adjusted: true
      )
      closed_count += 1
    end

    closed_count
  end

  def post_realized_pnl!(agent, closed_lot, realized_pnl)
    posting = Ledger::PostingService.new(
      source_type: "PositionLot",
      source_id: closed_lot.id,
      agent: agent.agent_id,
      asset: "USD",
      booked_at: closed_lot.closed_at || Time.current,
      description: "REBUILD Realized #{realized_pnl >= 0 ? 'gain' : 'loss'}: #{closed_lot.ticker}"
    )

    pnl_account = "agent:#{agent.agent_id}:realized_pnl"
    cost_adjustment = "agent:#{agent.agent_id}:cost_basis_adjustment"

    posting.add_entry(account_code: pnl_account, amount: realized_pnl, asset: "USD")
    posting.add_entry(account_code: cost_adjustment, amount: -realized_pnl, asset: "USD")

    posting.post!
  end
end

options = { apply: false }
OptionParser.new do |opts|
  opts.banner = "Usage: bin/rails runner script/rebuild_lots_and_ledger_from_fills.rb -- [--apply]"
  opts.on("--apply", "Persist changes (default dry-run)") { options[:apply] = true }
end.parse!(ARGV)

result = RebuildLotsAndLedgerFromFills.new.run!(apply: options[:apply])
puts result.to_h.to_json
