# frozen_string_literal: true

module Alpaca
  class ConsistencyService
    def initialize(positions: true, cash: true, qty_tolerance: 0.0001, cash_tolerance: 5.0)
      @positions = positions
      @cash = cash
      @qty_tolerance = qty_tolerance.to_f
      @cash_tolerance = cash_tolerance.to_f
      @broker = Alpaca::BrokerService.new
    end

    def call
      result = {
        ok: true,
        positions: nil,
        cash: nil
      }

      if @positions
        positions_result = check_positions
        result[:positions] = positions_result
        result[:ok] &&= positions_result[:ok]
      end

      if @cash
        cash_result = check_cash
        result[:cash] = cash_result
        result[:ok] &&= cash_result[:ok]
      end

      result
    end

    private

    def check_positions
      alpaca_positions = @broker.get_positions
      alpaca_map = Hash.new(0.0)
      alpaca_positions.each do |pos|
        ticker = normalize_symbol(pos[:ticker])
        alpaca_map[ticker] += pos[:qty].to_f
      end

      ledger_map = Hash.new(0.0)
      position_scope.group(:ticker).sum(:qty).each do |ticker, qty|
        ledger_map[normalize_symbol(ticker)] += qty.to_f
      end

      mismatches = []
      (alpaca_map.keys + ledger_map.keys).uniq.each do |ticker|
        alpaca_qty = alpaca_map[ticker].to_f
        ledger_qty = ledger_map[ticker].to_f

        next if alpaca_qty.abs <= @qty_tolerance && ledger_qty.abs <= @qty_tolerance

        diff = (ledger_qty - alpaca_qty).abs
        next unless diff > @qty_tolerance

        mismatches << {
          ticker: ticker,
          alpaca_qty: alpaca_qty,
          ledger_qty: ledger_qty,
          diff: ledger_qty - alpaca_qty
        }
      end

      {
        ok: mismatches.empty?,
        position_source: position_source,
        alpaca_count: alpaca_map.keys.count,
        ledger_count: ledger_map.keys.count,
        mismatches: mismatches
      }
    end

    def check_cash
      account = @broker.get_account
      unless account[:success] != false
        return { ok: false, error: account[:error] || "account fetch failed" }
      end

      projection = Ledger::ProjectionService.new
      internal_cash = if LedgerMigration.read_from_ledger?
                        projection.all_wallets.sum { |wallet| wallet[:cash].to_f }
                      else
                        Wallet.sum(:cash).to_f
                      end
      alpaca_cash = account[:cash].to_f
      diff = internal_cash - alpaca_cash

      {
        ok: diff.abs <= @cash_tolerance,
        cash_source: cash_source,
        internal_cash: internal_cash,
        ledger_cash: internal_cash,
        alpaca_cash: alpaca_cash,
        diff: diff
      }
    end

    def position_scope
      if LedgerMigration.read_from_ledger?
        PositionLot.where(closed_at: nil)
      else
        Position.where("ABS(qty) > ?", @qty_tolerance)
      end
    end

    def position_source
      LedgerMigration.read_from_ledger? ? "ledger_lots" : "legacy_positions"
    end

    def cash_source
      LedgerMigration.read_from_ledger? ? "ledger_wallets" : "legacy_wallets"
    end

    def normalize_symbol(symbol)
      sym = symbol.to_s.upcase
      return sym if sym.include?("/")
      return "#{sym[0..-4]}/USD" if sym.end_with?("USD") && sym.length > 3

      sym
    end
  end
end
