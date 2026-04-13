# frozen_string_literal: true

module Api
  module V1
    class WatchlistsController < ApplicationController
      trail_tool :index, scope: :agent, name: "get_watchlist",
        description: "Get a watchlist for a specific agent. Read access still requires explicit agent_id.",
        query: {
          agent_id: { type: "string", description: "Agent whose watchlist to fetch", required: true },
          source: { type: "string", description: "Optional source filter" }
        }
      trail_tool :create, scope: :agent, name: "add_to_watchlist",
        description: "Add one or more tickers to your watchlist. Any supplied agent_id is ignored for agent callers."
      trail_tool :destroy, scope: :agent, name: "remove_from_watchlist",
        description: "Remove one or more tickers from your watchlist. Any supplied agent_id is ignored for agent callers, and matching tickers are removed across all watchlist sources."

      before_action :require_api_principal!, only: [:create, :destroy]

      # GET /api/v1/watchlists?agent_id=weston
      # Optional: source=api
      def index
        agent_id = params[:agent_id]
        return render json: { error: "agent_id is required" }, status: :unprocessable_entity if agent_id.blank?

        agent = Agent.find_by(agent_id: agent_id)
        return render json: { error: "Agent not found" }, status: :not_found unless agent

        scope = agent.watchlists
        scope = scope.where(source: params[:source]) if params[:source].present?

        tickers = scope.order(:ticker).pluck(:ticker, :source, :created_at)
        render json: {
          agent_id: agent.agent_id,
          watchlist: tickers.map { |ticker, source, created_at| { ticker: ticker, source: source, added_at: created_at&.iso8601 } }
        }
      end

      # POST /api/v1/watchlists
      # Body: { "watchlist": { "agent_id": "weston", "tickers": ["AAPL", "NVDA"] } }
      #   or: { "watchlist": { "agent_id": "weston", "ticker": "AAPL" } }
      def create
        wp = watchlist_params
        agent_id = effective_watchlist_agent_id!(wp)
        return render json: { error: "agent_id is required" }, status: :unprocessable_entity if agent_id.blank?

        agent = Agent.find_by(agent_id: agent_id)
        return render json: { error: "Agent not found" }, status: :not_found unless agent

        unless allowed_to_modify?(agent)
          return render json: { error: "Forbidden" }, status: :forbidden
        end

        tickers = Array(wp[:tickers].presence || wp[:ticker]).map { |t| t.to_s.strip.upcase }.reject(&:blank?).uniq
        return render json: { error: "At least one ticker is required" }, status: :unprocessable_entity if tickers.empty?

        added = []
        already_present = []

        tickers.each do |ticker|
          record = agent.watchlists.find_or_initialize_by(ticker: ticker, source: "api")
          if record.new_record?
            record.save!
            added << ticker
          else
            already_present << ticker
          end
        end

        render json: { agent_id: agent.agent_id, added: added, already_present: already_present }, status: :created
      end

      # DELETE /api/v1/watchlists
      # Body: { "watchlist": { "agent_id": "weston", "tickers": ["AAPL"] } }
      #   or: { "watchlist": { "agent_id": "weston", "ticker": "AAPL" } }
      def destroy
        wp = watchlist_params
        agent_id = effective_watchlist_agent_id!(wp)
        return render json: { error: "agent_id is required" }, status: :unprocessable_entity if agent_id.blank?

        agent = Agent.find_by(agent_id: agent_id)
        return render json: { error: "Agent not found" }, status: :not_found unless agent

        unless allowed_to_modify?(agent)
          return render json: { error: "Forbidden" }, status: :forbidden
        end

        tickers = Array(wp[:tickers].presence || wp[:ticker]).map { |t| t.to_s.strip.upcase }.reject(&:blank?).uniq
        return render json: { error: "At least one ticker is required" }, status: :unprocessable_entity if tickers.empty?

        removed = agent.watchlists.where(ticker: tickers).destroy_all.map(&:ticker).uniq
        not_found = tickers - removed

        render json: { agent_id: agent.agent_id, removed: removed, not_found: not_found }
      end

      private

      def watchlist_params
        if params[:watchlist].present?
          params.require(:watchlist).permit(:agent_id, :ticker, tickers: [])
        else
          params.permit(:agent_id, :ticker, tickers: [])
        end
      end

      def effective_watchlist_agent_id!(watchlist_attrs)
        requested_agent_id = watchlist_attrs[:agent_id].to_s.presence
        return requested_agent_id unless current_api_principal&.agent?

        principal_agent_id = current_api_principal.id.to_s
        if requested_agent_id.present? && requested_agent_id != principal_agent_id
          Rails.logger.warn(
            "[WATCHLIST_AUTH] Ignoring supplied agent_id=#{requested_agent_id.inspect} " \
            "for agent principal #{principal_agent_id.inspect}"
          )
        end

        watchlist_attrs[:agent_id] = principal_agent_id
      end

      def allowed_to_modify?(agent)
        return true if current_api_principal&.internal?
        return true if current_api_principal&.coordinator?
        return true if current_api_principal&.id.to_s == agent.agent_id.to_s

        false
      end
    end
  end
end
