# frozen_string_literal: true

class MomentumMetricsCaptureService
  BENCHMARK_TICKERS = %w[SPY QQQ].freeze
  SOURCE = 'momentum_signals'
  RETURN_WINDOWS = {
    'price_return_15m' => 15.minutes,
    'price_return_1h' => 1.hour,
    'price_return_1d' => 1.day
  }.freeze
  RELATIVE_STRENGTH_WINDOWS = {
    'rs_vs_spy_15m' => ['SPY', 15.minutes],
    'rs_vs_qqq_15m' => ['QQQ', 15.minutes],
    'rs_vs_spy_1h' => ['SPY', 1.hour],
    'rs_vs_qqq_1h' => ['QQQ', 1.hour]
  }.freeze

  def initialize(tickers:, source: SOURCE)
    @tickers = Array(tickers).map { |ticker| normalize_ticker(ticker) }.compact.uniq
    @source = source
  end

  def call
    tickers = (@tickers + BENCHMARK_TICKERS).uniq
    rows = tickers.flat_map { |ticker| metric_rows_for(ticker) }
    return [] if rows.empty?

    TickerMetric.insert_all!(rows)
    rows
  end

  private

  def metric_rows_for(ticker)
    latest = latest_sample_for(ticker)
    return [] unless latest

    rows = []

    RETURN_WINDOWS.each do |metric_name, delta|
      value = return_decimal(ticker, delta, latest_price: latest.price, observed_at: latest.sampled_at)
      rows << build_row(ticker, metric_name, value, latest.sampled_at, meta: { window_seconds: delta.to_i }) unless value.nil?
    end

    RELATIVE_STRENGTH_WINDOWS.each do |metric_name, (benchmark_ticker, delta)|
      value = relative_strength_decimal(ticker, benchmark_ticker, delta, latest_price: latest.price, observed_at: latest.sampled_at)
      rows << build_row(ticker, metric_name, value, latest.sampled_at, meta: { benchmark: benchmark_ticker, window_seconds: delta.to_i }) unless value.nil?
    end

    volume_spike_1m = volume_spike_1m(ticker, latest)
    volume_spike_5m = volume_spike_5m(ticker, latest)
    unusual_volume = unusual_volume_flag(volume_spike_1m, volume_spike_5m)

    rows << build_row(ticker, 'volume_spike_1m', volume_spike_1m, latest.sampled_at, meta: { sample_count: 20 }) unless volume_spike_1m.nil?
    rows << build_row(ticker, 'volume_spike_5m', volume_spike_5m, latest.sampled_at, meta: { sample_count: 20 }) unless volume_spike_5m.nil?
    rows << build_row(ticker, 'unusual_volume_flag', unusual_volume, latest.sampled_at, meta: { threshold: 5.0 }) unless unusual_volume.nil?

    rows
  end

  def build_row(ticker, metric, value, observed_at, meta: nil)
    now = Time.current
    {
      ticker: ticker,
      metric: metric,
      value: value,
      observed_at: observed_at,
      source: @source,
      is_derived: true,
      meta: meta,
      created_at: now,
      updated_at: now
    }
  end

  def return_decimal(ticker, delta, latest_price:, observed_at:)
    reference_price = reference_price_for(ticker, delta, observed_at: observed_at)
    return nil if latest_price.nil? || reference_price.nil? || reference_price.to_f.zero?

    ((latest_price.to_f - reference_price.to_f) / reference_price.to_f).round(6)
  end

  def relative_strength_decimal(ticker, benchmark_ticker, delta, latest_price:, observed_at:)
    ticker_return = return_decimal(ticker, delta, latest_price: latest_price, observed_at: observed_at)
    benchmark_return = return_decimal(
      benchmark_ticker,
      delta,
      latest_price: latest_price_for(benchmark_ticker),
      observed_at: observed_at
    )
    return nil if ticker_return.nil? || benchmark_return.nil?

    (ticker_return - benchmark_return).round(6)
  end

  def volume_spike_1m(ticker, latest)
    current_volume = latest.volume.to_f
    return nil unless current_volume.positive?

    baseline_samples = baseline_volumes_for(ticker, before: latest.sampled_at - 5.minutes)
    return nil if baseline_samples.empty?

    (current_volume / average(baseline_samples)).round(4)
  end

  def volume_spike_5m(ticker, latest)
    window_start = latest.sampled_at - 4.minutes
    window_samples = sample_scope(ticker)
                     .where(sampled_at: window_start..latest.sampled_at)
                     .where.not(volume: nil)
                     .order(sampled_at: :asc)
    volumes = window_samples.pluck(:volume).map(&:to_f).select(&:positive?)
    return nil if volumes.empty?

    baseline_samples = baseline_volumes_for(ticker, before: window_start)
    return nil if baseline_samples.empty?

    expected_volume = average(baseline_samples) * volumes.length
    return nil if expected_volume <= 0

    (volumes.sum / expected_volume).round(4)
  end

  def unusual_volume_flag(volume_spike_1m, volume_spike_5m)
    return nil if volume_spike_1m.nil? && volume_spike_5m.nil?

    volume_spike_1m.to_f >= 5.0 || volume_spike_5m.to_f >= 5.0 ? 1.0 : 0.0
  end

  def average(values)
    return 0.0 if values.empty?

    values.sum / values.length.to_f
  end

  def baseline_volumes_for(ticker, before:)
    sample_scope(ticker)
      .where('sampled_at < ?', before)
      .where.not(volume: nil)
      .order(sampled_at: :desc)
      .limit(20)
      .pluck(:volume)
      .map(&:to_f)
      .select(&:positive?)
  end

  def latest_price_for(ticker)
    latest_sample_for(ticker)&.price
  end

  def latest_sample_for(ticker)
    sample_scope(ticker).order(sampled_at: :desc).first
  end

  def reference_price_for(ticker, delta, observed_at:)
    sample_scope(ticker)
      .where('sampled_at <= ?', observed_at - delta)
      .order(sampled_at: :desc)
      .limit(1)
      .pick(:price)
  end

  def sample_scope(ticker)
    resolved = resolved_sample_ticker(ticker)
    PriceSample.where(ticker: resolved)
  end

  def resolved_sample_ticker(ticker)
    return ticker unless ticker.to_s.include?('/')

    PriceSample.where(ticker: ticker).exists? ? ticker : ticker.delete('/')
  end

  def normalize_ticker(ticker)
    TickerNormalizer.normalize(ticker)
  end
end
