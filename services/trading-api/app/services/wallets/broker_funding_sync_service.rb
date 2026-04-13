# frozen_string_literal: true

module Wallets
  class BrokerFundingSyncService
    POSITION_TOLERANCE = 0.0001
    CASH_TOLERANCE = 0.01
    BROKER_FLAT_TOLERANCE = 1.0

    def initialize(snapshot: BrokerAccountSnapshot.latest, force: false)
      @snapshot = snapshot
      @force = force
    end

    def call
      return skipped_result("broker sync disabled") unless AppConfig.wallet_broker_sync_enabled?
      return error_result("no broker account snapshot found") unless @snapshot

      funded_ids = AppConfig.funded_trader_ids
      return error_result("no funded traders configured") if funded_ids.empty?

      funded_agents = Agent.includes(:wallet).where(agent_id: funded_ids).index_by(&:agent_id)
      missing_agents = funded_ids - funded_agents.keys
      return error_result("configured funded traders missing: #{missing_agents.join(', ')}") if missing_agents.any?

      book_state = current_book_state
      return skipped_result("desk is not flat", book_state: book_state) if !@force && !book_state[:flat]

      broker_state = current_broker_state
      return skipped_result("broker account is not flat", book_state: book_state, broker_state: broker_state) if !@force && !broker_state[:flat]

      capital = snapshot_capital
      return error_result("snapshot capital is not positive") unless capital.positive?

      allocations = equal_allocations(capital, funded_ids)

      ActiveRecord::Base.transaction do
        Agent.includes(:wallet).find_each do |agent|
          allocation = allocations.fetch(agent.agent_id, 0.0)
          wallet = agent.wallet || agent.build_wallet

          wallet.wallet_size = allocation
          wallet.cash = allocation
          wallet.invested = 0.0
          wallet.last_synced_at = @snapshot.fetched_at
          wallet.save!
        end
      end

      {
        success: true,
        applied: true,
        skipped: false,
        reason: nil,
        snapshot_fetched_at: @snapshot.fetched_at,
        snapshot_capital: capital,
        funded_trader_ids: funded_ids,
        allocations: allocations
      }
    rescue StandardError => e
      error_result(e.message)
    end

    private

    def current_book_state
      legacy_positions_count = Position.where("ABS(qty) > ?", POSITION_TOLERANCE).count
      ledger_positions_count = PositionLot.where(closed_at: nil).where("ABS(qty) > ?", POSITION_TOLERANCE).count
      invested_wallet_count = Wallet.where("ABS(invested) > ?", CASH_TOLERANCE).count

      {
        flat: legacy_positions_count.zero? && ledger_positions_count.zero? && invested_wallet_count.zero?,
        legacy_positions_count: legacy_positions_count,
        ledger_positions_count: ledger_positions_count,
        invested_wallet_count: invested_wallet_count
      }
    end

    def current_broker_state
      snapshot_cash = @snapshot.cash.to_f
      snapshot_equity = @snapshot.equity.to_f

      {
        broker_cash: snapshot_cash,
        broker_equity: snapshot_equity,
        broker_non_cash_value: (snapshot_equity - snapshot_cash).round(2),
        flat: (snapshot_equity - snapshot_cash).abs <= BROKER_FLAT_TOLERANCE
      }
    end

    def snapshot_capital
      cash = @snapshot.cash.to_f
      return cash if cash.positive?

      equity = @snapshot.equity.to_f
      return equity if equity.positive?

      @snapshot.portfolio_value.to_f
    end

    def equal_allocations(capital, funded_ids)
      cents = (BigDecimal(capital.to_s) * 100).round(0).to_i
      base_cents = cents / funded_ids.size
      remainder = cents % funded_ids.size

      funded_ids.each_with_index.each_with_object({}) do |(agent_id, index), allocations|
        allocation_cents = base_cents + (index < remainder ? 1 : 0)
        allocations[agent_id] = allocation_cents / 100.0
      end
    end

    def skipped_result(reason, book_state: current_book_state, broker_state: nil)
      {
        success: true,
        applied: false,
        skipped: true,
        reason: reason,
        snapshot_fetched_at: @snapshot&.fetched_at,
        snapshot_capital: @snapshot ? snapshot_capital : 0.0,
        funded_trader_ids: AppConfig.funded_trader_ids,
        book_state: book_state,
        broker_state: broker_state
      }
    end

    def error_result(message)
      {
        success: false,
        applied: false,
        skipped: false,
        error: message
      }
    end
  end
end
