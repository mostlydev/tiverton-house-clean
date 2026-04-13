module Admin
  class TradesController < BaseController
    def index
      @trades = Trade.includes(:agent)
                     .order(created_at: :desc)
                     .limit(100)

      if params[:status].present?
        @trades = @trades.where(status: params[:status])
      end

      if params[:agent_id].present?
        @trades = @trades.where(agent_id: params[:agent_id])
      end
    end

    def show
      @trade = Trade.includes(:agent, :trade_events).find(params[:id])
    end
  end
end
