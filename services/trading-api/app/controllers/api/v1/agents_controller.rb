module Api
  module V1
    class AgentsController < ApplicationController
      # GET /api/v1/agents
      def index
        @agents = Agent.includes(:wallet).order(:agent_id)

        render json: @agents.map { |agent| agent_json(agent) }
      end

      # GET /api/v1/agents/:id
      def show
        @agent = Agent.includes(:wallet, :positions, :trades).find(params[:id])

        render json: agent_json(@agent).merge(
          positions: @agent.positions.map { |p| position_summary(p) },
          trades: {
            total: @agent.trades.count,
            proposed: @agent.trades.proposed.count,
            approved: @agent.trades.approved.count,
            filled: @agent.trades.filled.count
          }
        )
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Agent not found' }, status: :not_found
      end

      # GET /api/v1/agents/:id/realized_pnl
      def realized_pnl
        @agent = Agent.find(params[:id])

        pnl_from_ledger = LedgerEntry
          .where(account_code: "agent:#{@agent.agent_id}:realized_pnl")
          .sum(:amount)
          .to_f

        pnl_from_lots = PositionLot
          .where(agent: @agent)
          .closed
          .sum(:realized_pnl)
          .to_f

        render json: {
          agent_id: @agent.agent_id,
          realized_pnl: pnl_from_ledger,
          realized_pnl_from_lots: pnl_from_lots,
          reconciled: (pnl_from_ledger - pnl_from_lots).abs < 0.01,
          closed_lots_count: PositionLot.where(agent: @agent).closed.count
        }
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Agent not found' }, status: :not_found
      end

      private

      def agent_json(agent)
        {
          id: agent.id,
          agent_id: agent.agent_id,
          name: agent.name,
          role: agent.role,
          style: agent.style,
          status: agent.status,
          wallet: wallet_json(agent.wallet),
          created_at: agent.created_at,
          updated_at: agent.updated_at
        }
      end

      def wallet_json(wallet)
        return nil unless wallet

        {
          wallet_size: wallet.wallet_size,
          cash: wallet.cash,
          invested: wallet.invested,
          total_value: wallet.total_value,
          allocation_percentage: wallet.allocation_percentage,
          cash_percentage: wallet.cash_percentage
        }
      end

      def position_summary(position)
        {
          ticker: position.ticker,
          qty: position.qty,
          avg_entry_price: position.avg_entry_price,
          current_value: position.current_value,
          unrealized_pnl: position.unrealized_pnl
        }
      end
    end
  end
end
