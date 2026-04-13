# frozen_string_literal: true

class TraderContextPrimeJob < ApplicationJob
  queue_as :low

  def perform(days: MarketDataBackfillService::DEFAULT_DAYS, tickers: nil)
    TraderContextPrimeService.new(days: days, tickers: tickers).call
  end
end
