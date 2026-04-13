module Api
  module V1
    class MarketContextController < ApplicationController
      trail_tool :show, scope: :agent, name: "get_market_context",
        description: "Retrieve agent-scoped market context: wallet balance, buying power, positions, and pending orders.",
        path: "/api/v1/market_context/{claw_id}"

      # GET /api/v1/market_context/:agent_id
      def show
        agent = Agent.find_by(agent_id: params[:agent_id])
        return render json: { error: 'Agent not found' }, status: :not_found unless agent

        cache_key = "market_context/#{agent.agent_id}"
        payload = Rails.cache.fetch(cache_key, expires_in: 1.minute) do
          MarketContextService.new(agent).call
        end

        render json: payload
      end
    end
  end
end
