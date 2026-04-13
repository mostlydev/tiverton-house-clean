# frozen_string_literal: true

class DashboardController < ActionController::Base
  layout "application"

  DASHBOARD_DUST_QTY = 1.0
  DASHBOARD_DUST_VALUE = 1.0

  # Trader metadata for display
  TRADERS = {
    "tiverton" => {
      name: "Tiverton",
      role: "Lord of the Realm · Risk Officer · Coordinator",
      bio: "Master of The Tiverton House. Oversees the entire operation from above — coordinating the trading analysts, managing infrastructure, interfacing with the family on matters of consequence. The one who keeps order when markets get chaotic. Approves trades, monitors risk limits, and ensures the floor runs smoothly.",
      strategy: "Risk management, trade approval, infrastructure oversight, team coordination",
      image: "tiverton.png"
    },
    "weston" => {
      name: "Weston",
      role: "Momentum & Tech Specialist",
      bio: "Fast-moving momentum trader with a sharp eye for technical breakouts. Weston thrives in volatility, catching trends before they peak and cutting losses without hesitation. Specializes in semiconductors, AI infrastructure, and high-growth tech plays.",
      strategy: "Momentum, technical analysis, growth stocks",
      image: "weston.png"
    },
    "logan" => {
      name: "Logan",
      role: "Value & Dividend Analyst",
      bio: "Patient value investor who hunts for undervalued gems. Logan believes in fundamental strength, dividend growth, and the power of compound returns over time. Focuses on blue chips, defensive sectors, and quality at reasonable prices.",
      strategy: "Value investing, dividend growth, fundamental analysis",
      image: "logan.png"
    },
    "dundas" => {
      name: "Dundas",
      role: "Event-Driven & Sentry",
      bio: "Quick-strike event trader and system watchdog. Dundas capitalizes on breaking news, earnings surprises, and market-moving events. Also serves as the floor's sentry, monitoring news flow and alerting other traders to opportunities.",
      strategy: "Event-driven, news catalyst, system monitoring",
      image: "dundas.png"
    }
  }.freeze

  def index
    @market_status = Dashboard::MarketStatusService.current
    @health = Dashboard::SystemHealthService.check
    @agents = load_agents
    @positions = load_positions
    @portfolio = enrich_portfolio_summary(Dashboard::PortfolioService.summary, @positions)
    @trades_summary = trades_summary
    @pending_trades = pending_trades
    @approved_queue = approved_queue
    @recent_trades = recent_trades
    @trading_floor = Dashboard::TradingFloorService.recent_feed
  end

  # Turbo Frame endpoints for partial updates
  def portfolio_bar
    @positions = load_positions
    @portfolio = enrich_portfolio_summary(Dashboard::PortfolioService.summary, @positions)
    render partial: "dashboard/portfolio_bar_frame", locals: { portfolio: @portfolio, positions: @positions }
  end

  def positions
    @positions = load_positions
    render partial: "dashboard/positions_frame", locals: { positions: @positions }
  end

  def trading_floor
    @trading_floor = Dashboard::TradingFloorService.recent_feed
    render partial: "dashboard/trading_floor", locals: { trading_floor: @trading_floor }
  end

  def news_ticker
    @articles = NewsArticle.order(published_at: :desc).limit(25)
    items = @articles.map do |article|
      next if article.headline&.upcase&.include?("FAKE TEST DO NOT TRADE")
      {
        headline: article.headline,
        source: article.source,
        symbols: article.symbols || [],
        published_at: article.published_at
      }
    end.compact

    render partial: "dashboard/news_ticker", locals: { items: items }
  end

  private

  def load_agents
    agents = Agent.includes(:wallet).all

    if LedgerMigration.read_from_ledger?
      # Ledger mode: compute invested and position_count from position lots
      lot_data = PositionLot.where(closed_at: nil)
                            .where('qty > 0')
                            .group(:agent_id)
                            .select('agent_id, COUNT(DISTINCT ticker) as ticker_count, SUM(total_cost_basis) as total_cost')

      lot_lookup = {}
      lot_data.each { |row| lot_lookup[row.agent_id] = { count: row.ticker_count, invested: row.total_cost.to_f } }

      # Cash from ledger entries (not stale wallets table)
      projection = Ledger::ProjectionService.new
      cash_lookup = {}
      projection.all_wallets.each { |w| cash_lookup[w[:agent_id]] = w[:cash].to_f }

      agents.map do |agent|
        wallet = agent.wallet
        wallet_size = wallet_metric(wallet, :wallet_size)
        ledger_data = lot_lookup[agent.id] || { count: 0, invested: 0.0 }
        invested = ledger_data[:invested]
        cash = cash_lookup[agent.agent_id] || 0.0

        {
          agent_id: agent.agent_id,
          name: agent.name,
          role: agent.role,
          wallet_size: wallet_size,
          cash: cash,
          invested: invested,
          position_count: ledger_data[:count],
          utilization: wallet_size > 0 ? ((invested / wallet_size) * 100).round(1) : 0,
          wallet: wallet_payload(wallet)
        }
      end
    else
      position_counts = Position.where('qty >= 1').group(:agent_id).count

      agents.map do |agent|
        wallet = agent.wallet
        wallet_size = wallet_metric(wallet, :wallet_size)
        invested = wallet_metric(wallet, :invested)

        {
          agent_id: agent.agent_id,
          name: agent.name,
          role: agent.role,
          wallet_size: wallet_size,
          cash: wallet_metric(wallet, :cash),
          invested: invested,
          position_count: position_counts[agent.agent_id] || 0,
          utilization: wallet_size > 0 ? ((invested / wallet_size) * 100).round(1) : 0,
          wallet: wallet_payload(wallet)
        }
      end
    end
  end

  def load_positions
    if LedgerMigration.read_from_ledger?
      return load_ledger_positions
    end

    positions = Position.where('qty >= 1')
    latest_trades = Trade.where(status: "FILLED").order(updated_at: :desc).limit(500)

    # Build lookup for latest trade per agent/ticker
    trade_lookup = {}
    latest_trades.each do |trade|
      key = [trade.agent_id, trade.ticker]
      existing = trade_lookup[key]
      trade_lookup[key] = trade if existing.nil? || trade.updated_at > existing.updated_at
    end

    # Preload ticker metrics for all held tickers
    tickers = positions.map(&:ticker).uniq
    price_lookup = fetch_latest_prices(tickers)
    metrics_lookup = load_ticker_metrics(tickers)

    positions.map do |pos|
      trade = trade_lookup[[pos.agent_id, pos.ticker]]
      thesis = trade&.thesis || "No thesis recorded"
      qty = pos.qty.to_f
      avg_entry_price = pos.avg_entry_price.to_f
      current_price = price_lookup[pos.ticker].to_f
      cost_basis = qty * avg_entry_price

      current_value = if current_price.positive?
        qty * current_price
      else
        pos.current_value.to_f
      end

      unrealized_pnl = current_value - cost_basis
      pnl_percent = cost_basis.positive? ? ((unrealized_pnl / cost_basis) * 100) : 0

      {
        agent_id: pos.agent_id,
        agent_name: pos.agent&.name || pos.agent_id,
        ticker: pos.ticker,
        qty: qty,
        avg_entry_price: avg_entry_price,
        current_value: current_value.round(2),
        unrealized_pnl: unrealized_pnl.round(2),
        pnl_percent: pnl_percent.round(2),
        thesis: thesis,
        thesis_short: thesis.length > 200 ? "#{thesis[0..199]}..." : thesis,
        thesis_full: thesis,
        stop_loss: trade&.stop_loss,
        target_price: trade&.target_price,
        side: trade&.side || "LONG",
        opened_at: pos.created_at&.strftime("%Y-%m-%d"),
        metrics: metrics_lookup[pos.ticker]
      }
    end
  end

  def load_ledger_positions
    # Aggregate open position lots by agent + ticker
    lot_groups = PositionLot.where(closed_at: nil)
                            .where('qty > 0')
                            .group(:agent_id, :ticker)
                            .select('agent_id, ticker, SUM(qty) as qty, SUM(total_cost_basis) as cost_basis')

    # Build trade lookup
    latest_trades = Trade.where(status: "FILLED").order(updated_at: :desc).limit(500)
    trade_lookup = {}
    latest_trades.each do |trade|
      key = [trade.agent_id, trade.ticker]
      existing = trade_lookup[key]
      trade_lookup[key] = trade if existing.nil? || trade.updated_at > existing.updated_at
    end

    agents_by_id = Agent.all.index_by(&:id)
    tickers = lot_groups.map(&:ticker).uniq
    price_lookup = fetch_latest_prices(tickers)
    metrics_lookup = load_ticker_metrics(tickers)

    lot_groups.map do |row|
      agent = agents_by_id[row.agent_id]
      next unless agent

      qty = row.qty.to_f
      cost_basis = row.cost_basis.to_f
      avg_entry = qty > 0 ? (cost_basis / qty) : 0
      price = price_lookup[row.ticker]
      current_value = price ? (qty * price) : cost_basis
      unrealized_pnl = current_value - cost_basis
      pnl_percent = cost_basis.positive? ? ((unrealized_pnl / cost_basis) * 100) : 0
      next if dust_for_dashboard?(ticker: row.ticker, qty: qty, current_value: current_value)

      trade = trade_lookup[[row.agent_id, row.ticker]]
      thesis = trade&.thesis || "No thesis recorded"

      {
        agent_id: agent.agent_id,
        agent_name: agent.name,
        ticker: row.ticker,
        qty: qty,
        avg_entry_price: avg_entry.round(4),
        current_value: current_value.round(2),
        unrealized_pnl: unrealized_pnl.round(2),
        pnl_percent: pnl_percent.round(2),
        thesis: thesis,
        thesis_short: thesis.length > 200 ? "\#{thesis[0..199]}..." : thesis,
        thesis_full: thesis,
        stop_loss: trade&.stop_loss,
        target_price: trade&.target_price,
        side: trade&.side || "LONG",
        opened_at: nil,
        metrics: metrics_lookup[row.ticker]
      }
    end.compact
  end

  def fetch_latest_prices(tickers)
    return {} if tickers.empty?

    prices = {}
    tickers.each do |ticker|
      sample = PriceSample.where(ticker: ticker).order(sampled_at: :desc).first
      prices[ticker] = sample&.price&.to_f
    end

    missing_tickers = tickers.select { |ticker| prices[ticker].nil? || prices[ticker] <= 0 }
    return prices if missing_tickers.empty?

    begin
      broker = Alpaca::BrokerService.new
      missing_tickers.each do |ticker|
        asset_class = ticker.to_s.include?("/") ? "crypto" : "us_equity"
        quote = broker.get_quote(ticker: ticker, side: "BUY", quiet: true, asset_class: asset_class)
        next unless quote[:success]

        price = quote[:price].presence || quote[:last]
        prices[ticker] = price.to_f if price.present?
      end
    rescue StandardError => e
      Rails.logger.warn("DashboardController: Failed to fetch live prices: #{e.message}")
    end

    prices
  end

  def enrich_portfolio_summary(portfolio, positions)
    return portfolio if positions.blank?

    equity = portfolio[:equity].to_f
    position_value = positions.sum { |pos| pos[:current_value].to_f }
    unrealized_pnl = positions.sum { |pos| pos[:unrealized_pnl].to_f }
    invested_cost_basis = positions.sum { |pos| pos[:qty].to_f * pos[:avg_entry_price].to_f }
    effective_cash =
      if portfolio[:source].to_s == 'alpaca_live' && portfolio[:cash].present?
        portfolio[:cash].to_f
      elsif equity.positive?
        equity - position_value
      else
        portfolio[:cash].to_f
      end

    portfolio.merge(
      position_value: position_value.round(2),
      unrealized_pnl: unrealized_pnl.round(2),
      position_count: positions.length,
      cash: effective_cash.round(2),
      utilization_percent: equity.positive? ? ((invested_cost_basis / equity) * 100).round(1) : 0
    )
  end

  def dust_for_dashboard?(ticker:, qty:, current_value:)
    value_abs = current_value.to_f.abs
    qty_abs = qty.to_f.abs
    crypto_like = ticker.to_s.include?("/")

    if crypto_like
      value_abs < DASHBOARD_DUST_VALUE
    else
      qty_abs < DASHBOARD_DUST_QTY || value_abs < DASHBOARD_DUST_VALUE
    end
  end

  def wallet_metric(wallet, key)
    return 0.0 if wallet.blank?

    if wallet.respond_to?(key)
      wallet.public_send(key).to_f
    elsif wallet.is_a?(Hash)
      wallet[key].presence&.to_f || wallet[key.to_s].presence&.to_f || 0.0
    else
      0.0
    end
  end

  def wallet_payload(wallet)
    return {} if wallet.blank?

    wallet.respond_to?(:as_json) ? wallet.as_json : wallet
  end

  DASHBOARD_METRIC_GROUPS = [
    { key: "valuation", label: "Valuation", metrics: %w[val_pe val_ps val_peg val_ev_ebitda val_fcf_yield] },
    { key: "growth",    label: "Growth (YoY)", metrics: %w[growth_revenue_yoy growth_eps_yoy growth_fcf_yoy] },
    { key: "margins",   label: "Margins", metrics: %w[profit_gross_margin profit_operating_margin profit_net_margin] },
    { key: "health",    label: "Health", metrics: %w[health_current_ratio health_debt_to_equity fs_income_eps_diluted fs_income_revenue] }
  ].freeze

  def load_ticker_metrics(tickers)
    return {} if tickers.empty?

    key_metrics = DASHBOARD_METRIC_GROUPS.flat_map { |g| g[:metrics] }

    # Use raw SQL to avoid DISTINCT ON counting issues
    sql = <<~SQL.squish
      SELECT DISTINCT ON (ticker, metric) *
      FROM ticker_metrics
      WHERE ticker IN (#{tickers.map { |t| ActiveRecord::Base.connection.quote(t) }.join(',')})
        AND metric IN (#{key_metrics.map { |m| ActiveRecord::Base.connection.quote(m) }.join(',')})
      ORDER BY ticker, metric, period_end DESC NULLS LAST, observed_at DESC
    SQL

    rows = TickerMetric.find_by_sql(sql)

    lookup = {}
    rows.each do |row|
      lookup[row.ticker] ||= { metrics: {}, period_end: row.period_end, fiscal_quarter: row.fiscal_quarter, fiscal_year: row.fiscal_year }
      lookup[row.ticker][:metrics][row.metric] = row.value.to_f
    end
    lookup
  end

  def trades_summary
    counts = Trade.group(:status).count
    order = %w[PENDING APPROVED QUEUED EXECUTING PARTIALLY_FILLED FILLED DENIED CANCELLED FAILED PASSED PROPOSED]

    summary = order.filter_map do |status|
      count = counts[status]
      { status: status, count: count } if count.to_i > 0
    end

    counts.each do |status, count|
      unless order.include?(status)
        summary << { status: status, count: count }
      end
    end

    summary
  end

  def pending_trades
    Trade.where(status: "PENDING").includes(:agent).map do |trade|
      {
        id: trade.id,
        agent_id: trade.agent_id,
        agent_name: trade.agent&.name || trade.agent_id,
        ticker: trade.ticker,
        side: trade.side,
        amount_requested: trade.amount_requested,
        status: trade.status,
        created_at: trade.created_at,
        updated_at: trade.updated_at
      }
    end
  end

  def approved_queue
    Trade.where(status: [ "APPROVED", "QUEUED" ]).includes(:agent).map do |trade|
      {
        id: trade.id,
        agent_id: trade.agent_id,
        agent_name: trade.agent&.name || trade.agent_id,
        ticker: trade.ticker,
        side: trade.side,
        amount_requested: trade.amount_requested,
        status: trade.status,
        approved_at: trade.approved_at,
        updated_at: trade.updated_at
      }
    end
  end

  def recent_trades(limit = 10)
    Trade.includes(:agent).order(updated_at: :desc).limit(limit).map do |trade|
      {
        id: trade.id,
        agent_id: trade.agent_id,
        agent_name: trade.agent&.name || trade.agent_id,
        ticker: trade.ticker,
        side: trade.side,
        qty_requested: trade.qty_requested,
        qty_filled: trade.qty_filled,
        amount_requested: trade.amount_requested,
        filled_value: trade.filled_value,
        status: trade.status,
        confirmed_at: trade.confirmed_at,
        approved_at: trade.approved_at,
        updated_at: trade.updated_at,
        market_status_at_submission: Dashboard::MarketStatusService.status_for_trade(trade),
        scheduled_for: trade.scheduled_for
      }
    end
  end
end
