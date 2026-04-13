# frozen_string_literal: true

module Api
  module V1
    class QuotesController < ApplicationController
      trail_tool :show, scope: :agent, name: "get_quote",
        description: "Get a live price quote for any ticker symbol."

      # GET /api/v1/quotes/:ticker
      def show
        ticker = params[:ticker].to_s.upcase
        asset_class = params[:asset_class] || "us_equity"

        result = Alpaca::BrokerService.new.get_quote(
          ticker: ticker,
          asset_class: asset_class
        )

        if result[:success]
          render json: {
            ticker: ticker,
            price: result[:price],
            bid: result[:bid],
            ask: result[:ask],
            last: result[:last],
            timestamp: Time.current.iso8601
          }
        else
          render json: { error: result[:error], ticker: ticker }, status: :service_unavailable
        end
      end
    end
  end
end
