# frozen_string_literal: true

class MarketContextService
  DUST_QTY = 1
  DUST_VALUE = 1.0

  def initialize(agent)
    @agent = agent
  end

  def call
    now_et = MarketHours.now
    locked = locked_payload
    {
      timestamp: now_et.strftime('%Y-%m-%d %H:%M:%S %Z'),
      market_status: MarketHours.status(now_et),
      positions: positions_payload,
      portfolio_value: portfolio_value,
      total_cost_basis: total_cost_basis,
      locked_cash: locked[:locked_buy],
      buying_power: locked[:available_cash],
      price_motion: price_motion_payload,
      wallet: wallet_payload,
      locked: locked,
      pending_orders: pending_orders_payload,
      recent_fills: recent_fills_payload
    }
  end

  private

  def use_ledger?
    LedgerMigration.read_from_ledger?
  end

  def ledger_positions
    @ledger_positions ||= begin
      projection = Ledger::ProjectionService.new
      positions = projection.positions_for_agent(@agent)

      # Enrich with prices
      positions.map do |pos|
        price = latest_price(pos[:ticker])
        current_value = price ? (pos[:qty].to_f * price) : pos[:cost_basis].to_f
        unrealized_pl = current_value - pos[:cost_basis].to_f
        unrealized_pl_pct = pos[:cost_basis].to_f > 0 ? (unrealized_pl / pos[:cost_basis].to_f * 100) : 0

        pos.merge(
          current_price: price,
          current_value: current_value,
          unrealized_pl: unrealized_pl,
          unrealized_pl_pct: unrealized_pl_pct
        )
      end
    end
  end

  def positions_scope
    if use_ledger?
      ledger_positions.select { |p| p[:qty].to_f.abs >= DUST_QTY && p[:current_value].to_f >= DUST_VALUE }
    else
      Position.by_agent(@agent.id)
              .where('ABS(qty) >= ?', DUST_QTY)
              .where('current_value IS NULL OR current_value >= ?', DUST_VALUE)
    end
  end

  def positions_payload
    if use_ledger?
      positions_scope.sort_by { |p| -p[:current_value].to_f }.map do |position|
        {
          ticker: position[:ticker],
          qty: position[:qty],
          avg_entry_price: position[:avg_cost_per_share],
          asset_class: infer_asset_class(position[:ticker]),
          current_value: position[:current_value],
          unrealized_pl: position[:unrealized_pl],
          unrealized_pl_pct: position[:unrealized_pl_pct]
        }
      end
    else
      positions_scope.includes(:agent).order(current_value: :desc).map do |position|
        {
          ticker: position.ticker,
          qty: position.qty,
          avg_entry_price: position.avg_entry_price,
          asset_class: position.asset_class,
          current_value: position.current_value,
          unrealized_pl: position.unrealized_pnl,
          unrealized_pl_pct: position.unrealized_pnl_percentage
        }
      end
    end
  end

  def portfolio_value
    if use_ledger?
      ledger_positions.sum { |p| p[:current_value].to_f }
    else
      positions_scope.sum(:current_value).to_f
    end
  end

  def total_cost_basis
    if use_ledger?
      ledger_positions.sum { |p| p[:cost_basis].to_f }
    else
      positions_scope.sum('qty * avg_entry_price').to_f
    end
  end

  def price_motion_payload
    positions = if use_ledger?
      ledger_positions.map { |p| p[:ticker] }
    else
      positions_scope.pluck(:ticker)
    end
    watchlist = Watchlist.where(agent_id: @agent.id).pluck(:ticker)
    watchlist_only = watchlist - positions

    {
      positions: price_snapshots_for(positions),
      watchlist: price_snapshots_for(watchlist_only)
    }
  end

  def infer_asset_class(ticker)
    return 'crypto' if ticker.to_s.include?('/')
    return 'us_option' if ticker.to_s.match?(/\A[A-Z]{1,6}\d{6}[CP]\d{8}\z/)
    'us_equity'
  end

  def price_snapshots_for(tickers)
    return [] if tickers.empty?

    tickers.map do |ticker|
      latest = latest_price(ticker)
      change_15m = pct_change(latest, ref_price(ticker, 15.minutes))
      change_1h = pct_change(latest, ref_price(ticker, 1.hour))
      change_1d = pct_change(latest, ref_price(ticker, 1.day))
      change_1w = pct_change(latest, ref_price(ticker, 1.week))
      change_1m = pct_change(latest, ref_price(ticker, 30.days))

      {
        ticker: ticker,
        last: latest,
        change_15m: change_15m,
        change_1h: change_1h,
        change_1d: change_1d,
        change_1w: change_1w,
        change_1m: change_1m,
        rs_vs_spy_15m: relative_strength(change_15m, benchmark_change('SPY', 15.minutes)),
        rs_vs_qqq_15m: relative_strength(change_15m, benchmark_change('QQQ', 15.minutes)),
        rs_vs_spy_1h: relative_strength(change_1h, benchmark_change('SPY', 1.hour)),
        rs_vs_qqq_1h: relative_strength(change_1h, benchmark_change('QQQ', 1.hour)),
        day_range: day_range(ticker)
      }
    end
  end

  def latest_price(ticker)
    price = PriceSample.where(ticker: ticker).order(sampled_at: :desc).limit(1).pick(:price)
    return price if price

    # Crypto tickers: positions use LINK/USD but Alpaca samples use LINKUSD
    if ticker.include?('/')
      PriceSample.where(ticker: ticker.delete('/')).order(sampled_at: :desc).limit(1).pick(:price)
    end
  end

  def ref_price(ticker, delta)
    price = PriceSample.where(ticker: resolve_sample_ticker(ticker))
               .where('sampled_at <= ?', Time.current - delta)
               .order(sampled_at: :desc)
               .limit(1)
               .pick(:price)
  end

  def day_range(ticker)
    scope = PriceSample.where(ticker: resolve_sample_ticker(ticker)).where('sampled_at >= ?', 1.day.ago)
    { low: scope.minimum(:price), high: scope.maximum(:price) }
  end

  def benchmark_change(ticker, delta)
    @benchmark_changes ||= {}
    key = [ticker, delta.to_i]
    @benchmark_changes[key] ||= begin
      latest = latest_price(ticker)
      ref = ref_price(ticker, delta)
      pct_change(latest, ref)
    end
  end

  def resolve_sample_ticker(ticker)
    return ticker unless ticker.include?('/')
    # Check if samples exist under slashed form first, fall back to de-slashed
    PriceSample.where(ticker: ticker).exists? ? ticker : ticker.delete('/')
  end

  def pct_change(latest, ref)
    return nil if latest.nil? || ref.nil? || ref.to_f.zero?
    ((latest.to_f - ref.to_f) / ref.to_f * 100).round(1)
  end

  def relative_strength(ticker_change, benchmark_change)
    return nil if ticker_change.nil? || benchmark_change.nil?

    (ticker_change.to_f - benchmark_change.to_f).round(1)
  end

  def wallet_payload
    if use_ledger?
      projection = Ledger::ProjectionService.new
      wallet = projection.wallet_for_agent(@agent)
      cash = wallet[:cash].to_f
      invested = ledger_positions.sum { |p| p[:cost_basis].to_f }
      wallet_size = @agent.wallet&.wallet_size.to_f

      {
        cash: cash,
        invested: invested,
        wallet_size: wallet_size,
        utilization_pct: wallet_size > 0 ? ((invested / wallet_size) * 100).round(0) : 0
      }
    else
      wallet = @agent.wallet
      return {} unless wallet

      {
        cash: wallet.cash,
        invested: wallet.invested,
        wallet_size: wallet.wallet_size,
        utilization_pct: wallet.wallet_size.to_f.zero? ? 0 : ((wallet.invested.to_f / wallet.wallet_size.to_f) * 100).round(0)
      }
    end
  end

  def locked_payload
    statuses = %w[APPROVED QUEUED EXECUTING PARTIALLY_FILLED]

    locked_buy = Trade.where(agent_id: @agent.id, side: 'BUY', status: statuses)
                      .sum("COALESCE(amount_requested, qty_requested * 100)")
                      .to_f

    locked_sells = Trade.where(agent_id: @agent.id, side: 'SELL', status: statuses)
                        .pluck(:ticker, :qty_requested)
                        .map { |ticker, qty| { ticker: ticker, qty: qty } }

    if use_ledger?
      projection = Ledger::ProjectionService.new
      wallet = projection.wallet_for_agent(@agent)
      cash = wallet[:cash].to_f
    else
      cash = @agent.wallet&.cash.to_f
    end

    # Agent market context should reflect the agent wallet, not desk-wide broker margin.
    available_cash = [cash - locked_buy, 0.0].max

    {
      locked_buy: locked_buy,
      available_cash: available_cash,
      account_buying_power: nil,
      locked_sells: locked_sells
    }
  end

  def pending_orders_payload
    statuses = %w[PROPOSED APPROVED QUEUED EXECUTING PARTIALLY_FILLED]
    Trade.where(agent_id: @agent.id, status: statuses).order(created_at: :desc).map do |trade|
      state = if trade.status == "QUEUED"
                "QUEUED"
      elsif trade.alpaca_order_id.present?
                "SUBMITTED"
      else
                "PENDING"
      end
      {
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
    Trade.where(agent_id: @agent.id, status: 'FILLED')
         .where('execution_completed_at > ?', 24.hours.ago)
         .order(execution_completed_at: :desc)
         .limit(5)
         .map do |trade|
      {
        ticker: trade.ticker,
        side: trade.side,
        qty: trade.qty_filled,
        price: trade.avg_fill_price,
        value: trade.filled_value,
        time: trade.execution_completed_at&.in_time_zone('Eastern Time (US & Canada)')&.strftime('%H:%M %Z')
      }
    end
  end
end
