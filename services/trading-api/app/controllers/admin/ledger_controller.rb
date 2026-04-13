module Admin
  class LedgerController < BaseController
    def index
      @entries = LedgerEntry.includes(:ledger_transaction)
                           .order(created_at: :desc)
                           .limit(200)

      if params[:agent_id].present?
        @entries = @entries.where(agent_id: params[:agent_id])
      end

      @transactions = LedgerTransaction.order(created_at: :desc).limit(50)
    end

    def transactions
      @transactions = LedgerTransaction.order(created_at: :desc)
                                      .limit(100)
    end

    def adjustments
      @adjustments = LedgerAdjustment.order(created_at: :desc)
                                    .limit(100)
    end
  end
end
