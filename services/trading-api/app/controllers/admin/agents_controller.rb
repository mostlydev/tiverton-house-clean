module Admin
  class AgentsController < BaseController
    def index
      @agents = Agent.all.order(:name)
    end

    def show
      @agent = Agent.find(params[:id])
      @trades = @agent.trades.order(created_at: :desc).limit(20)
      @positions = Position.where(agent_id: @agent.agent_id)
      @wallet = Wallet.find_by(agent_id: @agent.agent_id)
    end
  end
end
