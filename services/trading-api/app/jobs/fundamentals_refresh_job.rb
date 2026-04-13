# frozen_string_literal: true

class FundamentalsRefreshJob < ApplicationJob
  queue_as :low

  # Stagger per-ticker jobs to avoid rate-limiting the external API
  STAGGER_SECONDS = 3

  def perform(period: "quarterly", limit: 6)
    tickers = equity_tickers
    Rails.logger.info("[FundamentalsRefresh] Refreshing #{tickers.size} tracked equity tickers (period=#{period}, limit=#{limit})")

    tickers.each_with_index do |ticker, index|
      request = {
        fetcher: :fundamentals,
        ticker: ticker,
        script: TickerMetricsRefreshService::FETCHERS[:fundamentals][:script],
        args: [ticker, "--period", period, "--limit", limit.to_s],
        lock_key: "ticker_metrics_refresh:fundamentals:#{ticker}:#{period}",
        timeout: 120
      }

      TickerMetricsRefreshJob.set(wait: index * STAGGER_SECONDS).perform_later(request)
    end

    Rails.logger.info("[FundamentalsRefresh] Enqueued #{tickers.size} ticker refreshes")
  end

  private

  def equity_tickers
    TrackedEquityTickersService.new.call
  end
end
