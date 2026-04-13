# frozen_string_literal: true

module Api
  module V1
    class DeskPerformanceContextController < ApplicationController
      trail_tool :show, scope: :agent, name: "get_desk_performance",
        description: "Retrieve desk-wide performance totals with overall, week-to-date, and month-to-date P&L for funded active traders.",
        path: "/api/v1/desk_performance_context/{claw_id}"

      before_action :require_api_principal!
      before_action :load_requested_agent
      before_action :authorize_requested_agent!

      # GET /api/v1/desk_performance_context/:agent_id
      def show
        payload = Rails.cache.fetch("desk_performance_context", expires_in: 60.seconds) do
          Desk::PerformanceSummaryService.call
        end

        render json: payload
      end

      private

      def load_requested_agent
        @requested_agent = Agent.find_by(agent_id: params[:agent_id].to_s)
        return if @requested_agent.present?

        render json: { error: "Agent not found" }, status: :not_found
      end

      def authorize_requested_agent!
        return true if current_api_principal&.internal?
        return true if current_api_principal&.coordinator?
        return true if current_api_principal&.id.to_s == @requested_agent.agent_id.to_s

        render json: { error: "Forbidden" }, status: :forbidden
        false
      end
    end
  end
end
