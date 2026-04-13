# frozen_string_literal: true

class TraderContextPrimeService
  def initialize(
    days: MarketDataBackfillService::DEFAULT_DAYS,
    tickers: nil,
    include_benchmarks: true,
    end_time: Time.current,
    market_data_backfill_service_class: MarketDataBackfillService,
    dividend_snapshot_refresh_service_class: DividendSnapshotRefreshService
  )
    @days = days
    @requested_tickers = Array(tickers).map { |ticker| normalize_ticker(ticker) }.reject(&:blank?).uniq
    @include_benchmarks = include_benchmarks
    @end_time = end_time
    @market_data_backfill_service_class = market_data_backfill_service_class
    @dividend_snapshot_refresh_service_class = dividend_snapshot_refresh_service_class
  end

  def call
    equity_tickers = resolved_equity_tickers

    backfill = @market_data_backfill_service_class.new(
      days: @days,
      tickers: equity_tickers,
      include_benchmarks: @include_benchmarks,
      end_time: @end_time
    ).call

    snapshots = if equity_tickers.any?
                  @dividend_snapshot_refresh_service_class.new(
                    tickers: equity_tickers,
                    observed_at: @end_time
                  ).call
                else
                  []
                end

    {
      requested_tickers: @requested_tickers,
      equity_tickers: equity_tickers,
      include_benchmarks: @include_benchmarks,
      end_time: @end_time.iso8601,
      backfill: backfill,
      dividend_snapshots_written: Array(snapshots).size
    }
  end

  private

  def resolved_equity_tickers
    @resolved_equity_tickers ||= begin
      tickers = @requested_tickers.presence || TrackedEquityTickersService.new.call
      tickers.sort
    end
  end

  def normalize_ticker(ticker)
    TickerNormalizer.normalize(ticker)
  end
end
