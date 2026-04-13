module Admin
  class WalletsController < BaseController
    def index
      @wallets = Wallet.includes(:agent).all.order(:agent_id)
    end

    def show
      @wallet = Wallet.includes(:agent).find(params[:id])
      @ledger_entries = LedgerEntry.where(agent_id: @wallet.agent_id)
                                   .order(created_at: :desc)
                                   .limit(100)
    end
  end
end
