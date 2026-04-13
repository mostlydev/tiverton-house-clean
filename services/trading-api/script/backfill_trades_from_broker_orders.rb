# frozen_string_literal: true

# Usage:
#   bin/rails runner script/backfill_trades_from_broker_orders.rb -- [--apply]
# Default is dry-run.

require 'optparse'

class BackfillTradesFromBrokerOrders
  Result = Struct.new(
    :orders_scanned,
    :trades_created,
    :fills_linked,
    :ledger_posted,
    :skipped_no_fills,
    :skipped_existing_trade,
    keyword_init: true
  )

  def run!(apply: false)
    result = Result.new(
      orders_scanned: 0,
      trades_created: 0,
      fills_linked: 0,
      ledger_posted: 0,
      skipped_no_fills: 0,
      skipped_existing_trade: 0
    )

    ActiveRecord::Base.transaction do
      BrokerOrder.where(trade_id: nil).find_each do |order|
        result.orders_scanned += 1

        fills = BrokerFill.where(broker_order_id: order.id).order(:executed_at)
        if fills.empty?
          result.skipped_no_fills += 1
          next
        end

        trade = Trade.find_by(alpaca_order_id: order.broker_order_id)
        if trade
          result.skipped_existing_trade += 1
          link_fills_to_trade(trade, fills, result, apply: apply)
          next
        end

        agent = resolve_agent(order)
        trade_id = "external-#{order.broker_order_id}"

        qty_filled = fills.sum(:qty).to_f
        filled_value = fills.sum('qty * price').to_f
        avg_fill_price = qty_filled.positive? ? (filled_value / qty_filled) : 0

        trade_attrs = {
          trade_id: trade_id,
          agent: agent,
          ticker: order.ticker,
          side: order.side.to_s.upcase,
          qty_requested: qty_filled,
          order_type: normalize_order_type(order.order_type),
          status: 'FILLED',
          thesis: 'EXTERNAL_BACKFILL',
          approved_by: 'system',
          approved_at: order.submitted_at,
          confirmed_at: order.submitted_at,
          executed_by: 'system',
          execution_started_at: order.submitted_at,
          execution_completed_at: fills.last.executed_at,
          alpaca_order_id: order.broker_order_id,
          qty_filled: qty_filled,
          avg_fill_price: avg_fill_price,
          filled_value: filled_value,
          extended_hours: order.extended_hours || false,
          asset_class: normalize_asset_class(order.asset_class || infer_asset_class(order.ticker)),
          execution_policy: agent&.default_execution_policy || 'allow_extended'
        }

        result.trades_created += 1
        if apply
          trade = Trade.create!(trade_attrs)
          order.update!(trade: trade, agent: agent)
          link_fills_to_trade(trade, fills, result, apply: true)
        end
      end

      raise ActiveRecord::Rollback unless apply
    end

    result
  end

  private

  def resolve_agent(order)
    return order.agent if order.agent

    # Try to derive agent from client_order_id prefix
    cid = order.client_order_id.to_s
    if (match = cid.match(/\A([a-z]+)-/))
      agent = Agent.find_by(agent_id: match[1])
      return agent if agent
    end

    Agent.find_by(agent_id: 'system')
  end

  def normalize_order_type(order_type)
    ot = order_type.to_s.upcase
    return 'MARKET' if ot.empty?
    return ot if %w[MARKET LIMIT STOP STOP_LIMIT TRAILING_STOP].include?(ot)
    'MARKET'
  end

  def normalize_asset_class(asset_class)
    ac = asset_class.to_s
    return 'us_equity' if ac.empty?
    return ac if %w[us_equity us_option crypto crypto_perp].include?(ac)
    'us_equity'
  end

  def infer_asset_class(ticker)
    t = ticker.to_s
    return 'crypto' if t.include?('/')
    return 'us_option' if t.match?(/\A[A-Z]{1,6}\d{6}[CP]\d{8}\z/)
    'us_equity'
  end

  def link_fills_to_trade(trade, fills, result, apply:)
    fills.each do |fill|
      next if fill.trade_id == trade.id && fill.agent_id == trade.agent_id
      result.fills_linked += 1
      next unless apply
      fill.update!(trade: trade, agent: trade.agent)
      backfill_ledger_for_fill(fill, trade, result)
    end
  end

  def backfill_ledger_for_fill(fill, trade, result)
    return if LedgerTransaction.exists?(source_type: 'BrokerFill', source_id: fill.id)

    posting = Ledger::PostingService.new(
      source_type: 'BrokerFill',
      source_id: fill.id,
      agent: trade.agent.agent_id,
      asset: fill.ticker,
      booked_at: fill.executed_at,
      description: "BACKFILL #{fill.side.upcase} #{fill.qty} #{fill.ticker} @ #{fill.price}"
    )

    cash_account = "agent:#{trade.agent.agent_id}:cash"
    position_account = "agent:#{trade.agent.agent_id}:#{fill.ticker}"

    if fill.side == 'buy'
      posting.add_entry(account_code: position_account, amount: fill.value, asset: fill.ticker)
      posting.add_entry(account_code: cash_account, amount: -fill.value, asset: 'USD')
    else
      posting.add_entry(account_code: cash_account, amount: fill.value, asset: 'USD')
      posting.add_entry(account_code: position_account, amount: -fill.value, asset: fill.ticker)
    end

    posting.post!
    result.ledger_posted += 1
  end
end

options = { apply: false }
OptionParser.new do |opts|
  opts.banner = 'Usage: bin/rails runner script/backfill_trades_from_broker_orders.rb -- [--apply]'
  opts.on('--apply', 'Persist changes (default dry-run)') { options[:apply] = true }
end.parse!(ARGV)

result = BackfillTradesFromBrokerOrders.new.run!(apply: options[:apply])
puts result.to_h.to_json
