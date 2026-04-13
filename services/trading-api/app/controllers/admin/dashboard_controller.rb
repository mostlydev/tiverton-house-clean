module Admin
  class DashboardController < BaseController
    def index
      @stats = {
        trades: Trade.count,
        agents: Agent.count,
        positions: Position.count,
        wallets: Wallet.count,
        ledger_entries: LedgerEntry.count,
        recent_trades: Trade.order(created_at: :desc).limit(10),
        broker_fills: BrokerFill.count,
        outbox_events: OutboxEvent.count
      }
    end
  end
end
