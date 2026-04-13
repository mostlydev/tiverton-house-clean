# frozen_string_literal: true

module Ledger
  # Computes positions and wallets from ledger entries and position lots.
  # Supports as_of timestamp for historical queries.
  #
  # This is the read path for Phase 4 cutover - replaces direct reads from
  # legacy positions and wallets tables.
  class ProjectionService
    attr_reader :as_of

    def initialize(as_of: nil)
      @as_of = as_of || Time.current
    end

    # Get all positions for an agent from position lots
    # Returns array of position-like hashes
    def positions_for_agent(agent)
      agent = resolve_agent(agent)
      return [] unless agent

      lots = lots_query(agent)

      # Group by ticker and sum quantities
      lots.group(:ticker)
          .select('ticker, SUM(qty) as qty, SUM(total_cost_basis) as cost_basis')
          .having('SUM(qty) != 0')
          .map do |row|
        build_position_hash(agent, row)
      end
    end

    # Get a specific position for an agent/ticker
    def position_for(agent, ticker)
      agent = resolve_agent(agent)
      return nil unless agent

      lots = lots_query(agent).where(ticker: ticker.to_s.upcase)

      qty = lots.sum(:qty)
      return nil if qty.zero?

      cost_basis = lots.sum(:total_cost_basis)
      avg_cost = qty.nonzero? ? (cost_basis / qty).abs : 0

      {
        agent_id: agent.agent_id,
        ticker: ticker.to_s.upcase,
        qty: qty,
        cost_basis: cost_basis,
        avg_cost_per_share: avg_cost,
        source: 'ledger_lots',
        as_of: as_of
      }
    end

    # Get wallet (cash balance) for an agent from ledger entries
    def wallet_for_agent(agent)
      agent = resolve_agent(agent)
      return nil unless agent

      cash_account = "agent:#{agent.agent_id}:cash"
      cash = cash_balance(cash_account)

      {
        agent_id: agent.agent_id,
        cash: cash,
        source: 'ledger_entries',
        as_of: as_of
      }
    end

    # Get all wallets from ledger entries
    def all_wallets
      Agent.all.map do |agent|
        wallet_for_agent(agent)
      end.compact
    end

    # Get full portfolio summary for an agent
    def portfolio_for_agent(agent)
      agent = resolve_agent(agent)
      return nil unless agent

      positions = positions_for_agent(agent)
      wallet = wallet_for_agent(agent)

      # Calculate total position value (would need current prices)
      position_value = positions.sum { |p| p[:cost_basis] || 0 }

      {
        agent_id: agent.agent_id,
        cash: wallet[:cash],
        positions: positions,
        position_count: positions.size,
        total_cost_basis: position_value,
        source: 'ledger',
        as_of: as_of
      }
    end

    # Explain a position - show lot breakdown
    def explain_position(agent, ticker)
      agent = resolve_agent(agent)
      return nil unless agent

      lots = lots_query(agent)
              .where(ticker: ticker.to_s.upcase)
              .order(:opened_at)

      {
        agent_id: agent.agent_id,
        ticker: ticker.to_s.upcase,
        lots: lots.map { |lot| lot_to_hash(lot) },
        total_qty: lots.sum(&:qty),
        total_cost_basis: lots.sum(&:total_cost_basis),
        open_lots: lots.select { |l| l.closed_at.nil? }.size,
        closed_lots: lots.reject { |l| l.closed_at.nil? }.size,
        source: 'ledger_lots',
        as_of: as_of
      }
    end

    # Get cash transaction history for an agent
    def cash_history(agent, limit: 50)
      agent = resolve_agent(agent)
      return [] unless agent

      cash_account = "agent:#{agent.agent_id}:cash"

      entries = LedgerEntry
                .joins(:ledger_transaction)
                .where(account_code: cash_account)
                .where('ledger_transactions.booked_at <= ?', as_of)
                .order('ledger_transactions.booked_at DESC')
                .limit(limit)

      entries.map do |entry|
        {
          timestamp: entry.ledger_transaction.booked_at,
          amount: entry.amount,
          description: entry.ledger_transaction.description,
          source_type: entry.ledger_transaction.source_type,
          txn_id: entry.ledger_transaction.ledger_txn_id
        }
      end
    end

    private

    def resolve_agent(agent_or_id)
      return agent_or_id if agent_or_id.is_a?(Agent)
      return nil if agent_or_id.blank?

      Agent.find_by(agent_id: agent_or_id.to_s) || Agent.find_by(id: agent_or_id)
    end

    def lots_query(agent)
      query = PositionLot.where(agent: agent)

      # For as_of queries, include lots that were open at that time
      if as_of < Time.current
        query = query.where('opened_at <= ?', as_of)
                     .where('closed_at IS NULL OR closed_at > ?', as_of)
      else
        query = query.where(closed_at: nil)
      end

      query
    end

    def cash_balance(account_code)
      query = LedgerEntry
              .joins(:ledger_transaction)
              .where(account_code: account_code)

      if as_of < Time.current
        query = query.where('ledger_transactions.booked_at <= ?', as_of)
      end

      query.sum(:amount)
    end

    def build_position_hash(agent, row)
      qty = row.qty.to_f
      cost_basis = row.cost_basis.to_f
      avg_cost = qty.nonzero? ? (cost_basis / qty).abs : 0

      {
        agent_id: agent.agent_id,
        ticker: row.ticker,
        qty: qty,
        cost_basis: cost_basis,
        avg_cost_per_share: avg_cost,
        source: 'ledger_lots',
        as_of: as_of
      }
    end

    def lot_to_hash(lot)
      {
        id: lot.id,
        qty: lot.qty,
        cost_basis_per_share: lot.cost_basis_per_share,
        total_cost_basis: lot.total_cost_basis,
        opened_at: lot.opened_at,
        closed_at: lot.closed_at,
        open_source: "#{lot.open_source_type}:#{lot.open_source_id}",
        close_source: lot.closed_at ? "#{lot.close_source_type}:#{lot.close_source_id}" : nil,
        realized_pnl: lot.realized_pnl,
        bootstrap: lot.bootstrap_adjusted
      }
    end
  end
end
