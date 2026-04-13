# frozen_string_literal: true

module Api
  module V1
    class BrokerAccountSnapshotsController < ApplicationController
      before_action :require_coordinator_or_internal_api_principal!, only: :refresh

      def show
        snapshot = BrokerAccountSnapshot.latest
        return render json: { error: "No broker account snapshot found" }, status: :not_found unless snapshot

        render json: serialize(snapshot)
      end

      # POST /api/v1/broker_account_snapshot/refresh (local-only)
      def refresh
        result = BrokerAccountSnapshotService.new.call
        unless result[:success]
          return render json: { error: result[:error] }, status: :service_unavailable
        end

        render json: serialize(result[:snapshot]), status: :created
      end

      private

      def serialize(snapshot)
        payload = {
          broker: snapshot.broker,
          fetched_at: snapshot.fetched_at,
          cash: snapshot.cash&.to_f,
          buying_power: snapshot.buying_power&.to_f,
          equity: snapshot.equity&.to_f,
          portfolio_value: snapshot.portfolio_value&.to_f
        }

        payload[:raw_account] = snapshot.raw_account if params[:raw] == "true"
        payload
      end
    end
  end
end
