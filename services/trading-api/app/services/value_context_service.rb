# frozen_string_literal: true

class ValueContextService
  VALUE_METRICS = %w[
    yield_change_30d
    payout_growth_yoy
    beaten_down_score
    quality_value_score
  ].freeze
  FUNDAMENTAL_METRICS = %w[
    val_ev_ebitda
    val_fcf_yield
    health_current_ratio
    health_debt_to_equity
    health_interest_coverage
    profit_operating_margin
    growth_eps_yoy
  ].freeze

  def initialize(agent)
    @agent = agent
  end

  def call
    base_context = MarketContextService.new(@agent).call
    ranked = enriched_snapshots(base_context)

    {
      timestamp: base_context[:timestamp],
      market_status: base_context[:market_status],
      requested_by: requested_by_payload,
      leaders: ranked.first(5),
      watchlist: ranked,
      dividend_calendar: ranked.select { |row| row[:next_ex_date] }
                              .sort_by { |row| row[:days_until_ex_date] || 9_999 }
                              .first(5),
      scan_summary: {
        ticker_count: ranked.size,
        value_screen_matches: ranked.count { |row| row[:value_screen_match] },
        beaten_down_candidates: ranked.count { |row| row[:beaten_down_score].to_f >= 40.0 },
        ex_dates_within_30d: ranked.count { |row| row[:days_until_ex_date]&.between?(0, 30) }
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
    combined = deduped_snapshots(base_context)
    tickers = combined.map { |snapshot| snapshot[:ticker] }
    value_map = metrics_map(tickers, VALUE_METRICS, ValueMetricsCaptureService::SOURCE)
    fundamentals_map = metrics_map(tickers, FUNDAMENTAL_METRICS, nil)
    dividend_map = TickerDividendSnapshot.latest_by_ticker(tickers: tickers).index_by(&:ticker)

    combined.map do |snapshot|
      ticker = snapshot[:ticker]
      dividend_snapshot = dividend_map[ticker]
      value_metrics = value_map.fetch(ticker, {})
      fundamentals = fundamentals_map.fetch(ticker, {})
      payout_growth = value_metrics['payout_growth_yoy'] || dividend_snapshot&.payout_growth_yoy&.to_f

      snapshot.merge(
        val_ev_ebitda: fundamentals['val_ev_ebitda'],
        val_fcf_yield: fundamentals['val_fcf_yield'],
        health_current_ratio: fundamentals['health_current_ratio'],
        health_debt_to_equity: fundamentals['health_debt_to_equity'],
        health_interest_coverage: fundamentals['health_interest_coverage'],
        profit_operating_margin: fundamentals['profit_operating_margin'],
        growth_eps_yoy: fundamentals['growth_eps_yoy'],
        dividend_amount: dividend_snapshot&.dividend_amount&.to_f,
        annualized_dividend: dividend_snapshot&.annualized_dividend&.to_f,
        dividend_yield: dividend_snapshot&.dividend_yield&.to_f,
        yield_change_30d: value_metrics['yield_change_30d'] || dividend_snapshot&.yield_change_30d&.to_f,
        payout_ratio: dividend_snapshot&.payout_ratio&.to_f,
        payout_growth_yoy: payout_growth,
        next_ex_date: dividend_snapshot&.next_ex_date&.iso8601,
        next_pay_date: dividend_snapshot&.next_pay_date&.iso8601,
        days_until_ex_date: days_until(dividend_snapshot&.next_ex_date),
        beaten_down_score: value_metrics['beaten_down_score'],
        quality_value_score: value_metrics['quality_value_score'],
        value_screen_match: value_screen_match?(fundamentals, payout_growth)
      )
    end.sort_by do |snapshot|
      [
        snapshot[:value_screen_match] ? 0 : 1,
        snapshot[:days_until_ex_date] || 9_999,
        -snapshot[:beaten_down_score].to_f,
        -snapshot[:quality_value_score].to_f,
        -snapshot[:dividend_yield].to_f,
        snapshot[:ticker]
      ]
    end
  end

  def deduped_snapshots(base_context)
    position_rows = Array(base_context.dig(:price_motion, :positions)).map do |row|
      row.merge(ticker: normalize_ticker(row[:ticker]), in_position: true)
    end
    watchlist_rows = Array(base_context.dig(:price_motion, :watchlist)).map do |row|
      row.merge(ticker: normalize_ticker(row[:ticker]), in_position: false)
    end

    (position_rows + watchlist_rows).each_with_object({}) do |row, memo|
      ticker = row[:ticker]
      memo[ticker] = row if memo[ticker].blank?
      memo[ticker][:in_position] ||= row[:in_position]
    end.values
  end

  def metrics_map(tickers, metrics, source)
    return {} if tickers.empty? || metrics.empty?

    scope = TickerMetric.where(ticker: tickers, metric: metrics)
    scope = scope.where(source: source) if source.present?

    rows = scope.select('DISTINCT ON (ticker, metric) ticker_metrics.*')
                .order('ticker, metric, period_end DESC NULLS LAST, observed_at DESC')

    rows.each_with_object(Hash.new { |hash, key| hash[key] = {} }) do |row, memo|
      memo[row.ticker][row.metric] = row.value.to_f
    end
  end

  def value_screen_match?(fundamentals, payout_growth)
    ev_ebitda = fundamentals['val_ev_ebitda']
    return false unless ev_ebitda.to_f.positive? && ev_ebitda.to_f <= 12.0
    return false unless payout_growth.to_f > 0.05

    current_ratio = fundamentals['health_current_ratio']
    debt_to_equity = fundamentals['health_debt_to_equity']
    interest_coverage = fundamentals['health_interest_coverage']

    return false if current_ratio.present? && current_ratio.to_f < 0.8
    return false if debt_to_equity.present? && debt_to_equity.to_f > 2.0
    return false if interest_coverage.present? && interest_coverage.to_f < 2.5

    true
  end

  def days_until(date)
    return nil if date.blank?

    (date.to_date - Date.current).to_i
  end

  def normalize_ticker(ticker)
    TickerNormalizer.normalize(ticker)
  end
end
