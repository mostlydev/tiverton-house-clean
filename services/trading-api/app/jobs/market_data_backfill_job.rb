# frozen_string_literal: true

class MarketDataBackfillJob < ApplicationJob
  queue_as :low

  def perform(days: MarketDataBackfillService::DEFAULT_DAYS, tickers: nil)
    MarketDataBackfillService.new(days: days, tickers: tickers).call
  end
end
