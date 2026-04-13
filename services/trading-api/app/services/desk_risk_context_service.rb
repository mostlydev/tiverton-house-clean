# frozen_string_literal: true

class DeskRiskContextService
  PENDING_STATUSES = %w[PROPOSED APPROVED QUEUED EXECUTING PARTIALLY_FILLED].freeze
  CONCENTRATION_LIMIT_PCT = 25.0

  def initialize(requesting_agent)
    @requesting_agent = requesting_agent
  end

  def call
    now_et = MarketHours.now
    trader_data = trader_contexts
    positions = open_positions_payload(trader_data)
    wallets = trader_wallets_payload(trader_data)

    {
      timestamp: now_et.strftime('%Y-%m-%d %H:%M:%S %Z'),
      market_status: MarketHours.status(now_et),
      requested_by: requested_by_payload,
      trader_wallets: wallets,
      open_positions: positions,
      pending_orders: pending_orders_payload,
      recent_fills: recent_fills_payload,
      exposure_summary: exposure_summary_payload(wallets, positions),
      risk_alerts: risk_alerts_payload(wallets, positions)
    }
  end

  private

  def traders
    @traders ||= Agent.active.traders.includes(:wallet).order(:agent_id)
  end

  def trader_contexts
    @trader_contexts ||= traders.map do |agent|
      { agent: agent, context: MarketContextService.new(agent).call }
    end
  end

  def trader_wallets_payload(trader_data)
    trader_data.map do |entry|
      agent = entry[:agent]
      context = entry[:context]
      wallet = context[:wallet] || {}

      {
        agent_id: agent.agent_id,
        name: agent.name,
        style: agent.style,
        cash: wallet.fetch(:cash, 0).to_f,
        invested: wallet.fetch(:invested, 0).to_f,
        wallet_size: wallet.fetch(:wallet_size, 0).to_f,
        utilization_pct: wallet.fetch(:utilization_pct, 0).to_f,
        buying_power: context.fetch(:buying_power, 0).to_f,
        portfolio_value: context.fetch(:portfolio_value, 0).to_f,
        total_cost_basis: context.fetch(:total_cost_basis, 0).to_f,
        position_count: Array(context[:positions]).length
      }
    end
  end

  def open_positions_payload(trader_data)
    trader_data.flat_map do |entry|
      agent = entry[:agent]
      Array(entry[:context][:positions]).map do |position|
        {
          agent_id: agent.agent_id,
          name: agent.name,
          style: agent.style,
          ticker: position[:ticker],
          qty: position[:qty].to_f,
          avg_entry_price: position[:avg_entry_price].to_f,
          asset_class: position[:asset_class],
          current_value: position[:current_value].to_f,
          unrealized_pl: position[:unrealized_pl].to_f,
          unrealized_pl_pct: position[:unrealized_pl_pct].to_f
        }
      end
    end.sort_by { |position| -position[:current_value].to_f }
  end

  def pending_orders_payload
    Trade.includes(:agent)
         .where(agent_id: traders.map(&:id), status: PENDING_STATUSES)
         .order(created_at: :desc)
         .map do |trade|
      state = if trade.status == 'QUEUED'
                'QUEUED'
              elsif trade.alpaca_order_id.present?
                'SUBMITTED'
              else
                'PENDING'
              end

      {
        agent_id: trade.agent.agent_id,
        name: trade.agent.name,
        ticker: trade.ticker,
        side: trade.side,
        qty: trade.qty_requested,
        amount: trade.amount_requested,
        status: trade.status,
        state: state,
        asset_class: trade.asset_class,
        scheduled_for: trade.scheduled_for
      }
    end
  end

  def recent_fills_payload
    Trade.includes(:agent)
         .where(agent_id: traders.map(&:id), status: 'FILLED')
         .where('execution_completed_at > ?', 24.hours.ago)
         .order(execution_completed_at: :desc)
         .limit(10)
         .map do |trade|
      {
        agent_id: trade.agent.agent_id,
        name: trade.agent.name,
        ticker: trade.ticker,
        side: trade.side,
        qty: trade.qty_filled,
        price: trade.avg_fill_price,
        value: trade.filled_value,
        time: trade.execution_completed_at&.in_time_zone('Eastern Time (US & Canada)')&.strftime('%H:%M %Z')
      }
    end
  end

  def exposure_summary_payload(wallets, positions)
    by_agent = wallets.map do |wallet|
      {
        agent_id: wallet[:agent_id],
        name: wallet[:name],
        buying_power: wallet[:buying_power],
        cash: wallet[:cash],
        invested: wallet[:invested],
        wallet_size: wallet[:wallet_size],
        portfolio_value: wallet[:portfolio_value],
        position_count: wallet[:position_count]
      }
    end

    largest_position = positions.max_by { |position| position[:current_value].to_f }
    largest_position_payload =
      if largest_position
        wallet_size = wallets.find { |wallet| wallet[:agent_id] == largest_position[:agent_id] }&.fetch(:wallet_size, 0).to_f
        largest_position.merge(wallet_weight_pct: pct_of_wallet(largest_position[:current_value], wallet_size))
      end

    {
      trader_count: wallets.length,
      funded_trader_count: wallets.count { |wallet| wallet[:wallet_size].to_f.positive? },
      active_positions: positions.length,
      total_wallet_size: wallets.sum { |wallet| wallet[:wallet_size].to_f },
      total_cash: wallets.sum { |wallet| wallet[:cash].to_f },
      total_invested: wallets.sum { |wallet| wallet[:invested].to_f },
      portfolio_value: wallets.sum { |wallet| wallet[:portfolio_value].to_f },
      buying_power: wallets.sum { |wallet| wallet[:buying_power].to_f },
      largest_position: largest_position_payload,
      by_agent: by_agent
    }
  end

  def risk_alerts_payload(wallets, positions)
    alerts = []

    positions.each do |position|
      wallet = wallets.find { |entry| entry[:agent_id] == position[:agent_id] }
      next unless wallet

      concentration_pct = pct_of_wallet(position[:current_value], wallet[:wallet_size])
      next unless concentration_pct && concentration_pct > CONCENTRATION_LIMIT_PCT

      alerts << {
        type: 'position_concentration',
        severity: 'warning',
        agent_id: position[:agent_id],
        ticker: position[:ticker],
        current_value: position[:current_value],
        wallet_size: wallet[:wallet_size],
        concentration_pct: concentration_pct
      }
    end

    alerts
  end

  def requested_by_payload
    {
      agent_id: @requesting_agent.agent_id,
      name: @requesting_agent.name,
      role: @requesting_agent.role,
      style: @requesting_agent.style
    }
  end

  def pct_of_wallet(value, wallet_size)
    wallet = wallet_size.to_f
    return nil unless wallet.positive?

    ((value.to_f / wallet) * 100).round(1)
  end
end
