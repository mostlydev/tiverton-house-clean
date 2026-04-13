module Api
  module V1
    class WalletsController < ApplicationController
      before_action :set_wallet, only: [:show, :update]
      before_action :require_internal_api_principal!, only: :update

      # GET /api/v1/wallets
      def index
        if LedgerMigration.read_from_ledger?
          render_ledger_wallets
        else
          render_legacy_wallets
        end
      end

      # GET /api/v1/wallets/:id
      def show
        if LedgerMigration.read_from_ledger?
          render_ledger_wallet(@wallet.agent)
        else
          render json: wallet_json(@wallet)
        end
      end

      # PATCH /api/v1/wallets/:id
      def update
        if @wallet.update(wallet_params)
          render json: wallet_json(@wallet)
        else
          render json: { error: @wallet.errors.full_messages }, status: :unprocessable_entity
        end
      end

      private

      def set_wallet
        # Support lookup by agent_id or wallet id
        if params[:id].match?(/^\d+$/)
          @wallet = Wallet.includes(:agent).find(params[:id])
        else
          agent = Agent.find_by!(agent_id: params[:id])
          @wallet = agent.wallet
        end
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Wallet not found' }, status: :not_found
      end

      def wallet_params
        params.require(:wallet).permit(:wallet_size, :cash, :invested)
      end

      def render_legacy_wallets
        @wallets = Wallet.includes(:agent).all
        render json: {
          wallets: @wallets.map { |wallet| wallet_json(wallet) },
          source: 'legacy'
        }
      end

      def render_ledger_wallets
        projection = Ledger::ProjectionService.new
        wallets = projection.all_wallets

        # Calculate invested from position lots for each agent
        enriched = wallets.map do |w|
          agent = Agent.find_by(agent_id: w[:agent_id])
          next nil unless agent

          # Calculate invested from position lots (ledger source of truth)
          invested = calculate_invested_from_lots(agent)
          legacy = agent.wallet

          {
            agent_id: w[:agent_id],
            agent_name: agent.name,
            wallet_size: legacy&.wallet_size,
            cash: w[:cash],
            invested: invested,
            total_value: w[:cash] + invested,
            source: 'ledger'
          }
        end.compact

        render json: {
          wallets: enriched,
          source: 'ledger',
          as_of: projection.as_of
        }
      end

      def render_ledger_wallet(agent)
        projection = Ledger::ProjectionService.new
        ledger_wallet = projection.wallet_for_agent(agent)
        legacy = agent.wallet

        # Calculate invested from position lots (ledger source of truth)
        invested = calculate_invested_from_lots(agent)

        render json: {
          agent_id: agent.agent_id,
          agent_name: agent.name,
          wallet_size: legacy&.wallet_size,
          cash: ledger_wallet[:cash],
          invested: invested,
          total_value: ledger_wallet[:cash] + invested,
          source: 'ledger',
          as_of: projection.as_of
        }
      end

      # Calculate total invested from position lots (ledger source of truth)
      def calculate_invested_from_lots(agent)
        PositionLot
          .where(agent: agent, closed_at: nil)
          .sum(:total_cost_basis)
          .to_f
      end

      def wallet_json(wallet)
        {
          id: wallet.id,
          agent_id: wallet.agent.agent_id,
          agent_name: wallet.agent.name,
          wallet_size: wallet.wallet_size,
          cash: wallet.cash,
          invested: wallet.invested,
          total_value: wallet.total_value,
          allocation_percentage: wallet.allocation_percentage,
          cash_percentage: wallet.cash_percentage,
          updated_at: wallet.updated_at
        }
      end
    end
  end
end
