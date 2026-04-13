# frozen_string_literal: true

class TradersController < ActionController::Base
  layout "application"

  TRADERS = DashboardController::TRADERS

  def show
    name = trader_name_param
    return unless name

    @trader = trader_profile(name)
    return unless @trader

    agent = Agent.find_by(agent_id: name)
    agent_lookup_id = agent&.id || name
    use_ledger = LedgerMigration.read_from_ledger? && agent.present?
    trade_lookup = latest_trade_lookup(agent_lookup_id)

    @positions = position_snapshots_for(
      agent: agent,
      agent_lookup_id: agent_lookup_id,
      use_ledger: use_ledger,
      trade_lookup: trade_lookup,
      filter_dust: true
    )
    @watchlist = watchlist_for(agent)
    @wallet = wallet_summary_for(agent: agent, agent_lookup_id: agent_lookup_id, use_ledger: use_ledger, position_snapshots: @positions)
    @trades = trade_history_for(agent_lookup_id)

    assign_summary_state(agent: agent, agent_lookup_id: agent_lookup_id, use_ledger: use_ledger, position_snapshots: @positions, wallet_summary: @wallet)
  end

  def ledger
    name = trader_name_param
    return unless name

    @trader = trader_profile(name)
    return unless @trader

    agent = Agent.find_by(agent_id: name)
    unless agent
      render plain: "Agent not found", status: :not_found
      return
    end

    agent_lookup_id = agent.id

    use_ledger = LedgerMigration.read_from_ledger? && agent.present?

    position_snapshots = position_snapshots_for(
      agent: agent,
      agent_lookup_id: agent_lookup_id,
      use_ledger: use_ledger,
      trade_lookup: {},
      filter_dust: false
    )
    @watchlist = watchlist_for(agent)
    @wallet = wallet_summary_for(agent: agent, agent_lookup_id: agent_lookup_id, use_ledger: use_ledger, position_snapshots: position_snapshots)
    @trades = trade_history_for(agent_lookup_id)

    assign_summary_state(agent: agent, agent_lookup_id: agent_lookup_id, use_ledger: use_ledger, position_snapshots: position_snapshots, wallet_summary: @wallet)
  end

  private

  def trader_name_param
    name = params[:name].to_s.downcase

    unless name.match?(/\A[a-z]+\z/)
      render plain: "Invalid trader name", status: :bad_request
      return nil
    end

    name
  end

  def trader_profile(name)
    profile = TRADERS[name]
    unless profile&.fetch(:visible_on_public_pages, true)
      render plain: "Trader not found", status: :not_found
      return nil
    end

    profile.merge(id: name)
  end

  def watchlist_for(agent)
    return [] unless agent

    agent.watchlists.order(:ticker).pluck(:ticker).uniq
  end

  def latest_trade_lookup(agent_lookup_id)
    Trade.where(agent_id: agent_lookup_id, status: "FILLED").order(updated_at: :desc).limit(100).each_with_object({}) do |trade, lookup|
      existing = lookup[trade.ticker]
      lookup[trade.ticker] = trade if existing.nil? || trade.updated_at > existing.updated_at
    end
  end

  def position_snapshots_for(agent:, agent_lookup_id:, use_ledger:, trade_lookup:, filter_dust:)
    if use_ledger
      projection = Ledger::ProjectionService.new
      ledger_positions = projection.positions_for_agent(agent)
      ledger_prices = fetch_latest_prices(ledger_positions.map { |position| position[:ticker] }.uniq)

      build_ledger_positions(
        ledger_positions: ledger_positions,
        ledger_prices: ledger_prices,
        trade_lookup: trade_lookup,
        filter_dust: filter_dust
      )
    else
      positions = Position.where(agent_id: agent_lookup_id)
      build_legacy_positions(positions: positions, trade_lookup: trade_lookup, filter_dust: filter_dust)
    end
  end

  def wallet_summary_for(agent:, agent_lookup_id:, use_ledger:, position_snapshots:)
    current_position_value = position_snapshots.sum { |position| position[:current_value].to_f }

    if use_ledger
      wallet = Ledger::ProjectionService.new.wallet_for_agent(agent)
      cash = wallet&.[](:cash).to_f
      wallet_size = agent.wallet&.wallet_size.to_f
    else
      wallet = Wallet.find_by(agent_id: agent_lookup_id)
      cash = wallet&.cash.to_f
      wallet_size = wallet&.wallet_size.to_f
    end

    {
      cash: cash,
      invested: current_position_value,
      wallet_size: wallet_size,
      total_value: cash + current_position_value
    }
  end

  def trade_history_for(agent_lookup_id)
    trades = Trade.where(agent_id: agent_lookup_id, status: "FILLED")
                  .order(execution_completed_at: :asc)
                  .to_a

    fills_by_trade_id = BrokerFill.where(trade_id: trades.map(&:id)).group_by(&:trade_id)
    fill_ids = fills_by_trade_id.values.flatten.map(&:id)
    realized_pnl_by_fill_id =
      if fill_ids.any?
        PositionLot.closed.where(close_source_type: "BrokerFill", close_source_id: fill_ids).group(:close_source_id).sum(:realized_pnl)
      else
        {}
      end

    trades.map do |trade|
      fills = fills_by_trade_id[trade.id] || []
      realized_pnl = if trade.side == "SELL" && fills.any?
        fills.sum { |fill| realized_pnl_by_fill_id[fill.id].to_f }
      end

      {
        id: trade.id,
        trade_id: trade.trade_id,
        ticker: trade.ticker,
        side: trade.side,
        qty_filled: trade.qty_filled.to_f,
        avg_fill_price: trade.avg_fill_price.to_f,
        filled_value: trade.filled_value.to_f,
        realized_pnl: realized_pnl,
        thesis: trade.thesis,
        executed_at: trade.execution_completed_at
      }
    end
  end

  def realized_pnl_for(agent_lookup_id)
    PositionLot.where(agent_id: agent_lookup_id).closed.sum(:realized_pnl).to_f
  end

  def assign_summary_state(agent:, agent_lookup_id:, use_ledger:, position_snapshots:, wallet_summary:)
    if agent.present?
      performance = Traders::PerformanceSummaryService.for(agent)
      @realized_pnl = performance[:realized_pnl_overall]
      @unrealized_pnl = performance[:unrealized_pnl_current]
      @total_pnl = performance[:total_pnl_overall]
    else
      @realized_pnl = realized_pnl_for(agent_lookup_id)
      @unrealized_pnl = position_snapshots.sum { |position| position[:unrealized_pnl].to_f }
      @total_pnl = @realized_pnl + @unrealized_pnl
    end

    @starting_balance = starting_balance_for(agent: agent, agent_lookup_id: agent_lookup_id, use_ledger: use_ledger)
    @vs_starting = wallet_summary[:total_value] - @starting_balance

    totals = trade_totals(@trades)

    @summary = {
      starting_balance: @starting_balance,
      total_bought: totals[:buy_total],
      total_sold: totals[:sell_total],
      current_cash: wallet_summary[:cash],
      current_invested: wallet_summary[:invested],
      current_total: wallet_summary[:total_value],
      realized_pnl: @realized_pnl,
      unrealized_pnl: @unrealized_pnl,
      total_pnl: @total_pnl,
      vs_starting: @vs_starting,
      trade_count: @trades.length
    }
  end

  def starting_balance_for(agent:, agent_lookup_id:, use_ledger:)
    if use_ledger
      agent&.wallet&.wallet_size.to_f
    else
      Wallet.find_by(agent_id: agent_lookup_id)&.wallet_size.to_f
    end
  end

  def trade_totals(trades)
    {
      buy_total: trades.select { |trade| trade[:side] == "BUY" }.sum { |trade| trade[:filled_value] },
      sell_total: trades.select { |trade| trade[:side] == "SELL" }.sum { |trade| trade[:filled_value] }
    }
  end

  def build_legacy_positions(positions:, trade_lookup:, filter_dust:)
    price_lookup = fetch_latest_prices(positions.map(&:ticker).uniq)

    positions.filter_map do |pos|
      qty = pos.qty.to_f
      next if filter_dust && qty.abs < 1

      cost_basis = qty * pos.avg_entry_price.to_f
      price = price_lookup[pos.ticker]
      current_value = price ? (qty * price) : pos.current_value.to_f
      unrealized_pnl = current_value - cost_basis
      pnl_percent = cost_basis.positive? ? (unrealized_pnl / cost_basis * 100) : 0
      trade = trade_lookup[pos.ticker]

      {
        ticker: pos.ticker,
        qty: qty,
        avg_entry_price: pos.avg_entry_price.to_f,
        current_value: current_value.to_f,
        unrealized_pnl: unrealized_pnl.to_f,
        pnl_percent: pnl_percent.to_f,
        thesis: trade&.thesis || "No thesis recorded for this position.",
        stop_loss: trade&.stop_loss,
        target_price: trade&.target_price,
        side: trade&.side || "LONG"
      }
    end
  end

  def build_ledger_positions(ledger_positions:, ledger_prices:, trade_lookup:, filter_dust:)
    ledger_positions.filter_map do |pos|
      qty = pos[:qty].to_f
      next if filter_dust && qty.abs < 1

      price = ledger_prices[pos[:ticker]]
      current_value = price ? (qty * price) : pos[:cost_basis].to_f
      unrealized_pnl = current_value - pos[:cost_basis].to_f
      pnl_percent = pos[:cost_basis].to_f > 0 ? (unrealized_pnl / pos[:cost_basis].to_f * 100) : 0
      trade = trade_lookup[pos[:ticker]]

      {
        ticker: pos[:ticker],
        qty: qty,
        avg_entry_price: pos[:avg_cost_per_share].to_f,
        current_value: current_value.to_f,
        unrealized_pnl: unrealized_pnl.to_f,
        pnl_percent: pnl_percent.to_f,
        thesis: trade&.thesis || "No thesis recorded for this position.",
        stop_loss: trade&.stop_loss,
        target_price: trade&.target_price,
        side: trade&.side || "LONG"
      }
    end
  end

  def fetch_latest_prices(tickers)
    return {} if tickers.empty?

    prices = {}
    tickers.each do |ticker|
      sample = PriceSample.where(ticker: ticker).order(sampled_at: :desc).first
      prices[ticker] = sample&.price&.to_f
    end

    missing_tickers = tickers.select { |t| prices[t].nil? || prices[t] <= 0 }
    if missing_tickers.any?
      begin
        broker = Alpaca::BrokerService.new
        missing_tickers.each do |ticker|
          result = broker.get_quote(ticker: ticker, side: 'BUY', quiet: true)
          if result[:success]
            price = result[:price].presence || result[:last]
            prices[ticker] = price.to_f if price.present?
          end
        end
      rescue StandardError => e
        Rails.logger.warn("TradersController: Failed to fetch prices: #{e.message}")
      end
    end

    prices
  end
end
