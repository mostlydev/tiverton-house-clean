# frozen_string_literal: true

class ValueMetricsCaptureService
  SOURCE = 'value_signals'
  INPUT_METRICS = %w[
    val_ev_ebitda
    val_fcf_yield
    health_current_ratio
    health_debt_to_equity
    health_interest_coverage
    profit_operating_margin
    growth_eps_yoy
  ].freeze

  def initialize(tickers:, observed_at: Time.current, source: SOURCE)
    @tickers = Array(tickers).map { |ticker| normalize_ticker(ticker) }.reject(&:blank?).uniq
    @observed_at = observed_at
    @source = source
  end

  def call
    return [] if @tickers.empty?

    rows = @tickers.flat_map { |ticker| metric_rows_for(ticker) }
    return [] if rows.empty?

    TickerMetric.insert_all!(rows)
    rows
  end

  private

  def metric_rows_for(ticker)
    snapshot = latest_snapshots[ticker]
    rows = []

    rows << build_row(ticker, 'yield_change_30d', snapshot.yield_change_30d.to_f, snapshot.meta) if snapshot&.yield_change_30d
    rows << build_row(ticker, 'payout_growth_yoy', snapshot.payout_growth_yoy.to_f, snapshot.meta) if snapshot&.payout_growth_yoy

    quality_value_score = quality_value_score_for(ticker, snapshot)
    beaten_down_score = beaten_down_score_for(ticker, quality_value_score)

    rows << build_row(ticker, 'quality_value_score', quality_value_score, { snapshot_observed_at: snapshot&.observed_at&.iso8601 }) unless quality_value_score.nil?
    rows << build_row(ticker, 'beaten_down_score', beaten_down_score, { snapshot_observed_at: snapshot&.observed_at&.iso8601 }) unless beaten_down_score.nil?
    rows
  end

  def build_row(ticker, metric, value, meta)
    now = Time.current
    {
      ticker: ticker,
      metric: metric,
      value: value,
      observed_at: @observed_at,
      source: @source,
      is_derived: true,
      meta: meta,
      created_at: now,
      updated_at: now
    }
  end

  def quality_value_score_for(ticker, snapshot)
    metrics = input_metrics.fetch(ticker, {})
    components = []

    components << [inverse_scale(metrics['val_ev_ebitda'], best: 6.0, worst: 18.0), 35.0]
    components << [scale(metrics['val_fcf_yield'], min: 0.02, max: 0.08), 10.0]
    components << [scale(metrics['health_current_ratio'], min: 1.0, max: 2.0), 10.0]
    components << [inverse_scale(metrics['health_debt_to_equity'], best: 0.3, worst: 2.0), 15.0]
    components << [scale(metrics['health_interest_coverage'], min: 3.0, max: 10.0), 10.0]
    components << [scale(metrics['profit_operating_margin'], min: 0.05, max: 0.25), 10.0]
    components << [scale(metrics['growth_eps_yoy'], min: 0.0, max: 0.15), 5.0]
    components << [scale(snapshot&.dividend_yield&.to_f, min: 0.02, max: 0.06), 5.0]

    total_weight = components.sum { |value, weight| value.nil? ? 0.0 : weight }
    return nil if total_weight <= 0

    weighted_score = components.sum { |value, weight| value.to_f * weight }
    ((weighted_score / total_weight) * 100.0).round(2)
  end

  def beaten_down_score_for(ticker, quality_value_score)
    drawdown = drawdown_from_30d_high(ticker)
    return nil if drawdown.nil? && quality_value_score.nil?

    drawdown_component = if drawdown.present?
                           (clamp(drawdown, min: 0.0, max: 0.40) / 0.40) * 60.0
    end
    quality_component = quality_value_score.to_f * 0.4 if quality_value_score.present?

    (drawdown_component.to_f + quality_component.to_f).round(2)
  end

  def drawdown_from_30d_high(ticker)
    latest = latest_price(ticker)
    high = PriceSample.where(ticker: ticker)
                      .where('sampled_at >= ?', @observed_at - 30.days)
                      .maximum(:price)
                      &.to_f
    return nil unless latest.to_f.positive? && high.to_f.positive?
    return 0.0 if high <= latest

    ((high - latest) / high).round(6)
  end

  def latest_price(ticker)
    PriceSample.where(ticker: ticker).order(sampled_at: :desc).limit(1).pick(:price)&.to_f
  end

  def latest_snapshots
    @latest_snapshots ||= TickerDividendSnapshot.latest_by_ticker(tickers: @tickers).index_by(&:ticker)
  end

  def input_metrics
    @input_metrics ||= begin
      rows = TickerMetric.where(ticker: @tickers, metric: INPUT_METRICS)
                         .select('DISTINCT ON (ticker, metric) ticker_metrics.*')
                         .order('ticker, metric, period_end DESC NULLS LAST, observed_at DESC')

      rows.each_with_object(Hash.new { |hash, key| hash[key] = {} }) do |row, memo|
        memo[row.ticker][row.metric] = row.value.to_f
      end
    end
  end

  def scale(value, min:, max:)
    return nil if value.nil?
    return 0.0 if max <= min

    clamp((value.to_f - min) / (max - min), min: 0.0, max: 1.0)
  end

  def inverse_scale(value, best:, worst:)
    return nil if value.nil?
    return 0.0 if worst <= best

    clamp((worst - value.to_f) / (worst - best), min: 0.0, max: 1.0)
  end

  def clamp(value, min:, max:)
    [[value.to_f, min].max, max].min
  end

  def normalize_ticker(ticker)
    TickerNormalizer.normalize(ticker)
  end
end
