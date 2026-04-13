module Api
  module V1
    class DeskRiskContextController < ApplicationController
      before_action :require_coordinator_or_internal_api_principal!

      trail_tool :show, scope: :coordinator, name: "get_desk_risk_context",
        description: "Retrieve desk-wide risk context: trader wallets, positions, pending orders, recent fills, and risk alerts.",
        path: "/api/v1/desk_risk_context/{claw_id}"

      # GET /api/v1/desk_risk_context/:agent_id
      def show
        agent = Agent.find_by(agent_id: params[:agent_id])
        return render json: { error: 'Agent not found' }, status: :not_found unless agent

        cache_key = "desk_risk_context/#{agent.agent_id}"
        payload = Rails.cache.fetch(cache_key, expires_in: 30.seconds) do
          DeskRiskContextService.new(agent).call
        end

        render json: payload
      end
    end
  end
end
