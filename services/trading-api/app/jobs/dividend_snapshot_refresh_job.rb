# frozen_string_literal: true

class DividendSnapshotRefreshJob < ApplicationJob
  queue_as :low

  def perform(tickers: nil)
    tickers = Array(tickers).map { |ticker| TickerNormalizer.normalize(ticker) }.reject(&:blank?).uniq
    tickers = TrackedEquityTickersService.new.call if tickers.empty?
    return if tickers.empty?

    Rails.logger.info("[DividendSnapshotRefresh] Refreshing dividend snapshots for #{tickers.size} tickers")
    DividendSnapshotRefreshService.new(tickers: tickers).call
  end
end
