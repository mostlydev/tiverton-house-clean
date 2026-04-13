# frozen_string_literal: true

module Dashboard
  class PortfolioService
    def self.summary
      new.summary
    end

    def summary
      alpaca_data = fetch_alpaca_account

      if LedgerMigration.read_from_ledger?
        ledger_summary(alpaca_data)
      else
        legacy_summary(alpaca_data)
      end
    end

    private

    def ledger_summary(alpaca_data)
      projection = Ledger::ProjectionService.new
      ledger_wallets = projection.all_wallets
      ledger_cash = ledger_wallets.sum { |w| w[:cash].to_f }

      # Invested = total cost basis of open position lots
      invested = PositionLot.where(closed_at: nil)
                            .where('qty > 0')
                            .sum(:total_cost_basis).to_f

      live_equity = alpaca_data[:equity]

      # Equity: Alpaca is source of truth; fallback to ledger cash + invested
      equity = live_equity || (ledger_cash + invested)

      {
        equity: equity,
        cash: live_equity ? alpaca_data[:cash] : ledger_cash,
        internal_cash: ledger_cash,
        position_value: invested, # enriched with live prices by enrich_portfolio_summary
        unrealized_pnl: 0, # enriched by enrich_portfolio_summary
        utilization_percent: equity > 0 ? ((invested / equity) * 100).round(1) : 0,
        position_count: PositionLot.where(closed_at: nil).where('qty > 0').distinct.count(:ticker),
        wallet_last_synced_at: live_equity ? alpaca_data[:fetched_at] : Time.current,
        data_timestamp_label: live_equity ? 'Broker Snapshot' : 'Wallet Sync',
        source: live_equity ? 'alpaca_live' : 'ledger',
        buying_power: alpaca_data[:buying_power]
      }
    end

    def legacy_summary(alpaca_data)
      wallets = Wallet.all
      positions = Position.all

      total_cash = wallets.sum(&:cash)
      total_invested = wallets.where("wallet_size > 0").sum(&:invested)
      total_current_value = positions.sum(&:current_value)
      total_unrealized_pnl = positions.sum(&:unrealized_pnl)

      live_equity = alpaca_data[:equity]
      equity = live_equity || (total_cash + total_invested)
      effective_cash = live_equity ? alpaca_data[:cash] : total_cash

      {
        equity: equity,
        cash: effective_cash,
        internal_cash: total_cash,
        position_value: total_current_value,
        unrealized_pnl: total_unrealized_pnl.round(2),
        utilization_percent: equity > 0 ? ((total_invested / equity) * 100).round(1) : 0,
        position_count: positions.count,
        wallet_last_synced_at: live_equity ? alpaca_data[:fetched_at] : wallets.maximum(:last_synced_at),
        data_timestamp_label: live_equity ? 'Broker Snapshot' : 'Wallet Sync',
        source: live_equity ? 'alpaca_live' : 'internal',
        buying_power: alpaca_data[:buying_power]
      }
    end

    # Use BrokerAccountSnapshot (populated every 5 min by Sidekiq job) instead
    # of shelling out to the alpaca CLI. Falls back to API call if snapshot is stale.
    def fetch_alpaca_account
      snapshot = BrokerAccountSnapshot.latest
      if snapshot && snapshot.fetched_at > 10.minutes.ago
        return {
          equity: snapshot.equity.to_f,
          cash: snapshot.cash.to_f,
          portfolio_value: snapshot.portfolio_value.to_f,
          buying_power: snapshot.buying_power.to_f,
          fetched_at: snapshot.fetched_at
        }
      end

      # Snapshot stale or missing — direct API call
      account = Alpaca::BrokerService.new.get_account
      if account[:success]
        {
          equity: account[:equity],
          cash: account[:cash],
          portfolio_value: account[:portfolio_value],
          buying_power: account[:buying_power],
          fetched_at: Time.current
        }
      else
        Rails.logger.warn("PortfolioService: Alpaca account fetch failed: #{account[:error]}")
        {}
      end
    rescue StandardError => e
      Rails.logger.warn("PortfolioService: Error fetching Alpaca account: #{e.message}")
      {}
    end
  end
end
