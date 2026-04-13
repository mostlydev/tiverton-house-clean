module Api
  module V1
    class TradeEventsController < ApplicationController
      # GET /api/v1/trade_events
      def all
        events = TradeEvent.includes(:trade).order(:created_at).map do |event|
          {
            id: event.id,
            trade_id: event.trade.trade_id,
            event_type: event.event_type,
            actor: event.actor,
            details: event.details,
            created_at: event.created_at,
            updated_at: event.updated_at
          }
        end

        render json: events
      end

      # GET /api/v1/trades/:trade_id/events
      def index
        trade = find_trade
        return render json: { error: 'Trade not found' }, status: :not_found unless trade

        events = trade.trade_events.order(:created_at).map do |event|
          {
            id: event.id,
            trade_id: trade.trade_id,
            event_type: event.event_type,
            actor: event.actor,
            details: event.details,
            created_at: event.created_at,
            updated_at: event.updated_at
          }
        end

        render json: { trade_id: trade.trade_id, events: events }
      end

      private

      def find_trade
        trade_id_param = params[:trade_id].to_s
        if trade_id_param =~ /^\d+$/
          Trade.includes(:trade_events).find_by(id: trade_id_param)
        else
          Trade.includes(:trade_events).find_by(trade_id: trade_id_param)
        end
      end
    end
  end
end
