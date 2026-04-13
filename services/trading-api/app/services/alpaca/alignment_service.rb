# frozen_string_literal: true

module Alpaca
  class AlignmentService
    def initialize(apply: false, positions: true, cash: true, qty_tolerance: 0.0001, cash_tolerance: 5.0)
      @apply = apply
      @positions = positions
      @cash = cash
      @qty_tolerance = qty_tolerance.to_f
      @cash_tolerance = cash_tolerance.to_f
      @broker = Alpaca::BrokerService.new
      @system_agent = Agent.find_by(agent_id: "system")
    end

    def call
      return error_result("system agent not found") unless @system_agent

      result = {
        apply: @apply,
        positions: nil,
        cash: nil,
        ok: true
      }

      if @positions
        positions_result = align_positions
        result[:positions] = positions_result
        result[:ok] &&= positions_result[:ok]
      end

      if @cash
        cash_result = align_cash
        result[:cash] = cash_result
        result[:ok] &&= cash_result[:ok]
      end

      result
    rescue StandardError => e
      error_result(e.message)
    end

    private

    def align_positions
      alpaca_positions = @broker.get_positions
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

          next if diff.abs <= @qty_tolerance

          if diff.positive?
            basis = price_basis_for(ticker, alpaca_meta[ticker] || {})
            adjustments << { ticker: ticker, action: "add_lot", qty: diff, cost_basis: basis }
            next unless @apply

            PositionLot.create!(
              agent: @system_agent,
              ticker: ticker,
              qty: diff,
              cost_basis_per_share: basis,
              total_cost_basis: diff * basis,
              opened_at: Time.current,
              open_source_type: "AlpacaSync",
              open_source_id: 0,
              bootstrap_adjusted: true
            )
          else
            close_excess_lots(ticker, diff.abs, adjustments)
          end
        end

        raise ActiveRecord::Rollback unless @apply
      end

      {
        ok: adjustments.empty?,
        adjustments: adjustments
      }
    end

    def align_cash
      account = @broker.get_account
      unless account[:success] != false
        return { ok: false, error: account[:error] || "account fetch failed" }
      end

      projection = Ledger::ProjectionService.new
      ledger_cash = projection.all_wallets.sum { |wallet| wallet[:cash].to_f }
      alpaca_cash = account[:cash].to_f
      diff = alpaca_cash - ledger_cash
      cash_ok = diff.abs <= @cash_tolerance

      if !cash_ok && @apply
        post_cash_adjustment(diff)
      end

      {
        ok: cash_ok,
        ledger_cash: ledger_cash,
        alpaca_cash: alpaca_cash,
        diff: diff,
        adjusted: (!cash_ok && @apply)
      }
    end

    def close_excess_lots(ticker, remaining, adjustments)
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
        if @apply
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
            lot.update!(
              qty: new_qty,
              total_cost_basis: lot.cost_basis_per_share * new_qty,
              bootstrap_adjusted: true
            )

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

    def post_cash_adjustment(diff)
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

    def price_basis_for(ticker, alpaca_position)
      basis = alpaca_position[:avg_entry_price].to_f
      basis = alpaca_position[:current_price].to_f if basis <= 0
      basis = latest_price_for(ticker, fallback: 1.0) if basis <= 0
      basis
    end

    def latest_price_for(ticker, fallback: 1.0)
      sample = PriceSample.where(ticker: ticker).order(sampled_at: :desc).first
      return sample.price.to_f if sample&.price.to_f&.positive?

      fallback
    end

    def normalize_symbol(symbol)
      sym = symbol.to_s.upcase
      return sym if sym.include?("/")
      return "#{sym[0..-4]}/USD" if sym.end_with?("USD") && sym.length > 3

      sym
    end

    def error_result(message)
      {
        apply: @apply,
        positions: nil,
        cash: nil,
        ok: false,
        error: message
      }
    end
  end
end
