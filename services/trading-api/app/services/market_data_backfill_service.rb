# frozen_string_literal: true

class MarketDataBackfillService
  BENCHMARK_TICKERS = %w[SPY QQQ].freeze
  DEFAULT_DAYS = 30
  MAX_DAYS = 60
  DEFAULT_LIMIT = 10_000
  SOURCE = 'alpaca_history_backfill'

  def initialize(days: DEFAULT_DAYS, tickers: nil, include_benchmarks: true, end_time: Time.current, broker_service: Alpaca::BrokerService.new, source: SOURCE)
    @days = [[days.to_i, 1].max, MAX_DAYS].min
    @requested_tickers = Array(tickers).map { |ticker| normalize_ticker(ticker) }.reject(&:blank?).uniq
    @include_benchmarks = include_benchmarks
    @end_time = end_time.change(sec: 0)
    @broker_service = broker_service
    @source = source
  end

  def call
    results = {
      start_time: start_time.iso8601,
      end_time: @end_time.iso8601,
      tickers: {},
      total_bars: 0,
      updated_tickers: []
    }

    resolved_tickers.each do |ticker|
      ticker_result = backfill_ticker(ticker)
      results[:tickers][ticker] = ticker_result
      next unless ticker_result[:success]

      results[:updated_tickers] << ticker if ticker_result[:bars_written].to_i.positive?
      results[:total_bars] += ticker_result[:bars_written].to_i
    end

    recapture_momentum_metrics(results[:updated_tickers])
    results
  end

  private

  def start_time
    @start_time ||= (@end_time - @days.days).change(sec: 0)
  end

  def resolved_tickers
    base = @requested_tickers.presence || TrackedEquityTickersService.new.call
    tickers = base.dup
    tickers.concat(BENCHMARK_TICKERS) if @include_benchmarks
    tickers.uniq
  end

  def backfill_ticker(ticker)
    page_token = nil
    pages = 0
    bars_written = 0

    loop do
      response = @broker_service.get_historical_bars(
        ticker: ticker,
        start_time: start_time,
        end_time: @end_time,
        timeframe: '1Min',
        limit: DEFAULT_LIMIT,
        page_token: page_token,
        asset_class: 'us_equity',
        quiet: true
      )

      unless response[:success]
        return {
          success: false,
          error: response[:error],
          pages: pages,
          bars_written: bars_written
        }
      end

      bars = Array(response[:bars])
      break if bars.empty?

      pages += 1
      bars_written += upsert_bars(ticker, bars)
      page_token = response[:next_page_token]
      break if page_token.blank?
    end

    {
      success: true,
      pages: pages,
      bars_written: bars_written
    }
  rescue StandardError => e
    {
      success: false,
      error: e.message,
      pages: pages,
      bars_written: bars_written
    }
  end

  def upsert_bars(ticker, bars)
    rows = bars.filter_map do |bar|
      timestamp = parse_bar_timestamp(bar[:timestamp])
      next if timestamp.nil?

      {
        ticker: ticker,
        price: bar[:close],
        asset_class: 'us_equity',
        open_price: bar[:open],
        high_price: bar[:high],
        low_price: bar[:low],
        close_price: bar[:close],
        volume: bar[:volume],
        trade_count: bar[:trade_count],
        vwap: bar[:vwap],
        sampled_at: timestamp,
        sample_minute: timestamp.strftime('%Y-%m-%d %H:%M:00'),
        source: @source,
        created_at: Time.current,
        updated_at: Time.current
      }
    end
    return 0 if rows.empty?

    PriceSample.upsert_all(rows, unique_by: :idx_price_samples_unique_minute)
    rows.size
  end

  def parse_bar_timestamp(value)
    return value if value.is_a?(Time)

    Time.zone.parse(value.to_s)
  rescue ArgumentError, TypeError
    nil
  end

  def recapture_momentum_metrics(tickers)
    return if tickers.empty?

    MomentumMetricsCaptureService.new(tickers: tickers).call
  rescue StandardError => e
    Rails.logger.error("MarketDataBackfill: momentum metric capture failed (#{e.class}: #{e.message})")
  end

  def normalize_ticker(ticker)
    TickerNormalizer.normalize(ticker)
  end
end
