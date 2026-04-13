# frozen_string_literal: true

# Usage:
#   bin/rails runner script/fix_broker_order_links.rb -- [--apply]
# Default is dry-run.

require 'optparse'

class FixBrokerOrderLinks
  Result = Struct.new(
    :linked_orders,
    :created_orders,
    :linked_fills,
    :linked_fills_to_trades,
    :orphan_fills,
    :deduped_fills,
    keyword_init: true
  )

  def run!(apply: false)
    result = Result.new(
      linked_orders: 0,
      created_orders: 0,
      linked_fills: 0,
      linked_fills_to_trades: 0,
      orphan_fills: [],
      deduped_fills: 0
    )

    ActiveRecord::Base.transaction do
      dedupe_conflicting_fills(result, apply: apply)
      link_orders_to_trades(result, apply: apply)
      backfill_orders_for_trades(result, apply: apply)
      link_fills_to_orders(result, apply: apply)
      link_fills_to_trades(result, apply: apply)

      raise ActiveRecord::Rollback unless apply
    end

    result
  end

  private

  def link_orders_to_trades(result, apply:)
    BrokerOrder.where(trade_id: nil).find_each do |order|
      trade = Trade.find_by(alpaca_order_id: order.broker_order_id)
      next unless trade

      result.linked_orders += 1
      next unless apply

      updates = { trade_id: trade.id, agent_id: trade.agent_id }
      updates[:ticker] = trade.ticker if order.ticker.blank?
      updates[:side] = trade.side.to_s.downcase if order.side.blank?
      updates[:order_type] = trade.order_type.to_s.downcase if order.order_type.blank?
      updates[:asset_class] = trade.asset_class if order.asset_class.blank?
      order.update!(updates)
    end
  end

  def dedupe_conflicting_fills(result, apply:)
    BrokerFill.where(broker_order_id: nil).find_each do |fill|
      order_id = extract_order_id(fill)
      next unless order_id

      order = BrokerOrder.find_by(broker_order_id: order_id)
      next unless order

      existing = BrokerFill.where(broker_order_id: order.id, executed_at: fill.executed_at, qty: fill.qty).to_a
      next if existing.empty?

      canonical = choose_canonical(existing + [fill])
      next if canonical.id == fill.id

      result.deduped_fills += 1
      next unless apply

      merge_fill_into!(fill, canonical)
    end
  end

  def backfill_orders_for_trades(result, apply:)
    missing = Trade.where.not(alpaca_order_id: nil)
                   .where.not(alpaca_order_id: BrokerOrder.select(:broker_order_id))

    missing.find_each do |trade|
      result.created_orders += 1
      next unless apply

      BrokerOrder.create!(
        broker_order_id: trade.alpaca_order_id,
        client_order_id: trade.trade_id,
        trade: trade,
        agent: trade.agent,
        ticker: trade.ticker,
        side: trade.side.to_s.downcase,
        order_type: trade.order_type.to_s.downcase.presence || 'market',
        time_in_force: nil,
        requested_tif: nil,
        effective_tif: nil,
        extended_hours: trade.extended_hours,
        qty_requested: trade.qty_requested,
        notional_requested: trade.amount_requested,
        limit_price: trade.limit_price,
        stop_price: trade.stop_price,
        trail_percent: trade.trail_percent,
        trail_price: trade.trail_amount,
        status: trade.status.to_s.downcase,
        submitted_at: trade.execution_started_at || trade.created_at,
        filled_at: trade.execution_completed_at,
        raw_request: { source: 'backfill_trade', trade_id: trade.trade_id },
        raw_response: { source: 'backfill_trade' },
        asset_class: trade.asset_class
      )
    end
  end

  def link_fills_to_orders(result, apply:)
    BrokerFill.where(broker_order_id: nil).find_each do |fill|
      order_id = extract_order_id(fill)
      unless order_id
        result.orphan_fills << fill.id
        next
      end

      order = BrokerOrder.find_by(broker_order_id: order_id)
      unless order
        order = create_stub_order(order_id, fill)
      end

      result.linked_fills += 1
      next unless apply

      fill.update!(broker_order: order)
    end
  end

  def link_fills_to_trades(result, apply:)
    BrokerFill.includes(:broker_order).where(trade_id: nil).find_each do |fill|
      trade_id = fill.broker_order&.trade_id
      next unless trade_id

      result.linked_fills_to_trades += 1
      next unless apply

      fill.update!(trade_id: trade_id)
    end
  end

  def extract_order_id(fill)
    raw = normalize_raw(fill.raw_fill)
    raw[:order_id] || (fill.trade&.alpaca_order_id)
  end

  def normalize_raw(raw_fill)
    if raw_fill.is_a?(String)
      begin
        raw_fill = JSON.parse(raw_fill)
      rescue StandardError
        raw_fill = {}
      end
    end

    return {} unless raw_fill.is_a?(Hash)

    raw_fill.each_with_object({}) do |(k, v), out|
      out[k.to_sym] = v
    end
  end

  def create_stub_order(order_id, fill)
    raw = normalize_raw(fill.raw_fill)
    symbol = (raw[:symbol] || raw[:ticker] || fill.ticker || 'UNKNOWN').to_s
    side = (raw[:side] || fill.side || 'buy').to_s
    status = (raw[:status] || 'filled').to_s
    order_type = (raw[:order_type] || 'market').to_s
    submitted_at = raw[:transaction_time] || fill.executed_at

    BrokerOrder.create!(
      broker_order_id: order_id,
      client_order_id: "external-#{order_id}",
      trade: fill.trade,
      agent: fill.trade&.agent,
      ticker: symbol.upcase,
      side: side.downcase,
      order_type: order_type.downcase,
      status: status,
      submitted_at: submitted_at,
      filled_at: fill.executed_at,
      raw_request: { source: 'backfill_fill' },
      raw_response: raw,
      asset_class: infer_asset_class(symbol)
    )
  rescue ActiveRecord::RecordNotUnique
    BrokerOrder.find_by(broker_order_id: order_id)
  end

  def infer_asset_class(ticker)
    return 'crypto' if ticker.include?('/')
    return 'us_option' if ticker.match?(/\A[A-Z]{1,6}\d{6}[CP]\d{8}\z/)
    'us_equity'
  end

  def choose_canonical(fills)
    fills.compact!
    return fills.first if fills.size == 1

    fills.sort_by do |f|
      [
        f.broker_fill_id.nil? ? 1 : 0,
        f.trade_id.nil? ? 1 : 0,
        f.id.to_i
      ]
    end.first
  end

  def merge_fill_into!(duplicate, canonical)
    # Re-point lots to canonical fill
    PositionLot.where(open_source_type: 'BrokerFill', open_source_id: duplicate.id)
               .update_all(open_source_id: canonical.id)
    PositionLot.where(close_source_type: 'BrokerFill', close_source_id: duplicate.id)
               .update_all(close_source_id: canonical.id)

    dup_txn = LedgerTransaction.find_by(source_type: 'BrokerFill', source_id: duplicate.id)
    canon_txn = LedgerTransaction.find_by(source_type: 'BrokerFill', source_id: canonical.id)

    if dup_txn
      if canon_txn
        LedgerEntry.where(ledger_transaction_id: dup_txn.id).delete_all
        LedgerAdjustment.where(ledger_transaction_id: dup_txn.id).delete_all
        dup_txn.delete
      else
        dup_txn.update!(source_id: canonical.id)
      end
    end

    duplicate.delete
  end
end

options = { apply: false }
OptionParser.new do |opts|
  opts.banner = 'Usage: bin/rails runner script/fix_broker_order_links.rb -- [--apply]'
  opts.on('--apply', 'Persist changes (default is dry-run)') { options[:apply] = true }
end.parse!(ARGV)

result = FixBrokerOrderLinks.new.run!(apply: options[:apply])
puts result.to_h.to_json
