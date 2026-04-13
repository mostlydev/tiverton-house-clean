module Api
  module V1
    class AssetsController < ApplicationController
      # GET /api/v1/assets?asset_class=crypto
      def index
        asset_class = params[:asset_class].presence || "us_equity"

        symbols = Rails.cache.fetch("assets:symbols:#{asset_class}", expires_in: 12.hours) do
          broker = Alpaca::BrokerService.new
          broker.get_asset_symbols(asset_class: asset_class)&.to_a&.sort || []
        end

        render json: { symbols: symbols, asset_class: asset_class, count: symbols.size }
      end
    end
  end
end
