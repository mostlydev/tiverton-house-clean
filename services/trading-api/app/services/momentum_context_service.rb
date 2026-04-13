# frozen_string_literal: true

class MomentumContextService
  BENCHMARK_TICKERS = %w[SPY QQQ].freeze
  MOMENTUM_METRICS = %w[
    volume_spike_1m
    volume_spike_5m
    unusual_volume_flag
    price_return_15m
    price_return_1h
    rs_vs_spy_15m
    rs_vs_qqq_15m
    rs_vs_spy_1h
    rs_vs_qqq_1h
  ].freeze

  def initialize(agent)
    @agent = agent
  end

  def call
    base_context = MarketContextService.new(@agent).call
    snapshots = enriched_snapshots(base_context)

    {
      timestamp: base_context[:timestamp],
      market_status: base_context[:market_status],
      requested_by: requested_by_payload,
      benchmarks: benchmark_payload,
      leaders: snapshots.first(5),
      watchlist: snapshots,
      scan_summary: {
        ticker_count: snapshots.size,
        unusual_volume_count: snapshots.count { |row| row[:unusual_volume] },
        in_position_count: snapshots.count { |row| row[:in_position] }
      }
    }
  end

  private

  def requested_by_payload
    {
      agent_id: @agent.agent_id,
      name: @agent.name,
      role: @agent.role,
      style: @agent.style
    }
  end

  def enriched_snapshots(base_context)
    position_snapshots = Array(base_context.dig(:price_motion, :positions))
    watchlist_snapshots = Array(base_context.dig(:price_motion, :watchlist))
    combined = position_snapshots.map { |snapshot| snapshot.merge(in_position: true) } +
               watchlist_snapshots.map { |snapshot| snapshot.merge(in_position: false) }
    tickers = combined.map { |snapshot| normalize_ticker(snapshot[:ticker]) }.uniq
    metrics_map = latest_metrics_map(tickers)

    combined.map do |snapshot|
      ticker = normalize_ticker(snapshot[:ticker])
      metrics = metrics_map.fetch(ticker, {})
      unusual_volume = metrics.fetch('unusual_volume_flag', 0).to_f >= 1.0

      snapshot.merge(
        ticker: ticker,
        volume_spike_1m: metrics['volume_spike_1m'],
        volume_spike_5m: metrics['volume_spike_5m'],
        unusual_volume: unusual_volume
      )
    end.sort_by do |snapshot|
      [
        snapshot[:unusual_volume] ? 0 : 1,
        -snapshot[:volume_spike_5m].to_f,
        -snapshot[:rs_vs_spy_15m].to_f,
        -snapshot[:change_15m].to_f,
        snapshot[:ticker]
      ]
    end
  end

  def benchmark_payload
    base_metrics = latest_metrics_map(BENCHMARK_TICKERS)

    BENCHMARK_TICKERS.map do |ticker|
      metrics = base_metrics.fetch(ticker, {})
      {
        ticker: ticker,
        last: latest_price(ticker),
        change_15m: pct_change(latest_price(ticker), reference_price(ticker, 15.minutes)),
        change_1h: pct_change(latest_price(ticker), reference_price(ticker, 1.hour)),
        volume_spike_1m: metrics['volume_spike_1m'],
        volume_spike_5m: metrics['volume_spike_5m']
      }
    end
  end

  def latest_metrics_map(tickers)
    return {} if tickers.empty?

    rows = TickerMetric.where(ticker: tickers, metric: MOMENTUM_METRICS, source: MomentumMetricsCaptureService::SOURCE)
                       .select('DISTINCT ON (ticker, metric) ticker_metrics.*')
                       .order('ticker, metric, observed_at DESC')

    rows.each_with_object(Hash.new { |hash, key| hash[key] = {} }) do |row, memo|
      memo[row.ticker][row.metric] = row.value.to_f
    end
  end

  def latest_price(ticker)
    sample_scope(ticker).order(sampled_at: :desc).limit(1).pick(:price)&.to_f
  end

  def reference_price(ticker, delta)
    sample_scope(ticker)
      .where('sampled_at <= ?', Time.current - delta)
      .order(sampled_at: :desc)
      .limit(1)
      .pick(:price)
      &.to_f
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

  def pct_change(latest, ref)
    return nil if latest.nil? || ref.nil? || ref.zero?

    (((latest - ref) / ref) * 100).round(1)
  end
end
