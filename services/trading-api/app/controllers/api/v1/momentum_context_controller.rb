module Api
  module V1
    class MomentumContextController < ApplicationController
      trail_tool :show, scope: :agent, name: "get_momentum_context",
        description: "Retrieve momentum-ranked watchlist context with relative strength and unusual-volume signals.",
        path: "/api/v1/momentum_context/{claw_id}"

      # GET /api/v1/momentum_context/:agent_id
      def show
        agent = Agent.find_by(agent_id: params[:agent_id])
        return render json: { error: 'Agent not found' }, status: :not_found unless agent

        cache_key = "momentum_context/#{agent.agent_id}"
        payload = Rails.cache.fetch(cache_key, expires_in: 1.minute) do
          MomentumContextService.new(agent).call
        end

        render json: payload
      end
    end
  end
end
