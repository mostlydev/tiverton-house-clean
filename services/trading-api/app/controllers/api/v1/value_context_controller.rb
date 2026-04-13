module Api
  module V1
    class ValueContextController < ApplicationController
      # GET /api/v1/value_context/:agent_id
      def show
        agent = Agent.find_by(agent_id: params[:agent_id])
        return render json: { error: 'Agent not found' }, status: :not_found unless agent

        cache_key = "value_context/#{agent.agent_id}"
        payload = Rails.cache.fetch(cache_key, expires_in: 5.minutes) do
          ValueContextService.new(agent).call
        end

        render json: payload
      end
    end
  end
end
