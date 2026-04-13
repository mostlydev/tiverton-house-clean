# frozen_string_literal: true

# Provides compatibility layer for reading positions/wallets from ledger.
# When LEDGER_READ_SOURCE=ledger, these methods return ledger-derived values.
module LedgerCompatible
  extend ActiveSupport::Concern

  class_methods do
    # Override query methods to use ledger when configured
    def ledger_positions_for(agent)
      return none unless LedgerMigration.read_from_ledger?

      projection = Ledger::ProjectionService.new
      projection.positions_for_agent(agent).map do |pos|
        LedgerPositionProxy.new(pos, agent)
      end
    end

    def ledger_wallet_for(agent)
      return nil unless LedgerMigration.read_from_ledger?

      projection = Ledger::ProjectionService.new
      wallet_data = projection.wallet_for_agent(agent)
      LedgerWalletProxy.new(wallet_data, agent) if wallet_data
    end
  end

  # Proxy object that quacks like a Position but reads from ledger
  class LedgerPositionProxy
    attr_reader :agent, :ticker, :qty, :cost_basis, :avg_entry_price

    def initialize(position_hash, agent)
      @agent = agent
      @ticker = position_hash[:ticker]
      @qty = position_hash[:qty]
      @cost_basis = position_hash[:cost_basis]
      @avg_entry_price = position_hash[:avg_cost_per_share]
      @source = 'ledger'
    end

    def id
      "ledger:#{agent.agent_id}:#{ticker}"
    end

    def current_value
      # Would need current price - fall back to cost basis
      @cost_basis
    end

    def unrealized_pnl
      current_value - cost_basis
    end

    def unrealized_pnl_percentage
      return 0 if cost_basis.zero?
      (unrealized_pnl / cost_basis * 100).round(2)
    end

    def opened_at
      # Could query first lot's opened_at
      nil
    end

    def updated_at
      Time.current
    end

    def source
      'ledger'
    end

    def persisted?
      false
    end
  end

  # Proxy object that quacks like a Wallet but reads from ledger
  class LedgerWalletProxy
    attr_reader :agent, :cash

    def initialize(wallet_hash, agent)
      @agent = agent
      @cash = wallet_hash[:cash]
      @source = 'ledger'
    end

    def id
      "ledger:#{agent.agent_id}"
    end

    def wallet_size
      # Get from legacy wallet
      agent.wallet&.wallet_size || 0
    end

    def invested
      # Calculate from ledger positions
      projection = Ledger::ProjectionService.new
      positions = projection.positions_for_agent(agent)
      positions.sum { |p| p[:cost_basis] || 0 }
    end

    def total_value
      cash + invested
    end

    def allocation_percentage
      return 0 if wallet_size.zero?
      (invested / wallet_size * 100).round(2)
    end

    def cash_percentage
      return 0 if total_value.zero?
      (cash / total_value * 100).round(2)
    end

    def updated_at
      Time.current
    end

    def source
      'ledger'
    end

    def persisted?
      false
    end
  end
end
