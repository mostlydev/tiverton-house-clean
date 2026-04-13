# frozen_string_literal: true

class DividendSnapshotRefreshService
  SOURCE = 'dividend_snapshot'
  CORPORATE_ACTION_TYPES = ['cash_dividend'].freeze

  def initialize(tickers:, broker_service: Alpaca::BrokerService.new, source: SOURCE, observed_at: Time.current)
    @tickers = Array(tickers).map { |ticker| normalize_ticker(ticker) }.reject(&:blank?).uniq
    @broker_service = broker_service
    @source = source
    @observed_at = observed_at
  end

  def call
    return [] if @tickers.empty?

    actions_by_ticker = upcoming_actions_by_ticker
    snapshots = @tickers.filter_map do |ticker|
      snapshot_for(ticker, actions_by_ticker[ticker])
    end

    ValueMetricsCaptureService.new(tickers: @tickers, observed_at: @observed_at).call
    snapshots
  end

  private

  def snapshot_for(ticker, action)
    dividend_amount = latest_metric_value(ticker, 'fs_income_dividends_per_share')
    annualized_dividend = dividend_amount&.positive? ? (dividend_amount * 4.0).round(6) : nil
    price_row = latest_price_row(ticker)
    current_price = price_row&.price&.to_f
    dividend_yield = if annualized_dividend.present? && current_price.to_f.positive?
                       (annualized_dividend / current_price.to_f).round(6)
    end
    payout_growth_yoy = payout_growth_yoy_for(ticker, dividend_amount)
    yield_change_30d, yield_change_source = yield_change_30d_for(ticker, annualized_dividend, dividend_yield)
    payout_ratio = payout_ratio_for(ticker, dividend_amount)

    return nil if action.blank? && annualized_dividend.nil? && payout_ratio.nil? && payout_growth_yoy.nil?

    TickerDividendSnapshot.create!(
      ticker: ticker,
      source: @source,
      observed_at: @observed_at,
      next_ex_date: action&.fetch(:ex_date, nil),
      next_pay_date: action&.fetch(:pay_date, nil),
      dividend_amount: dividend_amount,
      annualized_dividend: annualized_dividend,
      dividend_yield: dividend_yield,
      yield_change_30d: yield_change_30d,
      payout_ratio: payout_ratio,
      payout_growth_yoy: payout_growth_yoy,
      meta: snapshot_meta(action, current_price, price_row, yield_change_source: yield_change_source)
    )
  end

  def snapshot_meta(action, current_price, price_row, yield_change_source:)
    meta = {
      price: current_price,
      price_sampled_at: price_row&.sampled_at&.iso8601,
      yield_change_30d_source: yield_change_source
    }.compact

    return meta if action.blank?

    meta.merge(
      corporate_action_id: action[:id],
      declaration_date: action[:declaration_date]&.iso8601,
      record_date: action[:record_date]&.iso8601,
      cash_amount: action[:cash]
    ).compact
  end

  def payout_ratio_for(ticker, dividend_amount)
    return nil unless dividend_amount.to_f.positive?

    eps = latest_metric_value(ticker, 'fs_income_eps_diluted') || latest_metric_value(ticker, 'fs_income_eps')
    return nil unless eps.to_f.positive?

    (dividend_amount.to_f / eps.to_f).round(6)
  end

  def payout_growth_yoy_for(ticker, current_dividend_amount)
    return nil unless current_dividend_amount.to_f.positive?

    records = TickerMetric.where(
      ticker: ticker,
      metric: 'fs_income_dividends_per_share',
      source: 'financial_datasets',
      period_type: 'quarterly'
    ).order(period_end: :desc, observed_at: :desc).limit(8).to_a

    current = records.find { |record| record.value.to_f.positive? }
    prior = if current&.period_end
              records.find { |record| record.period_end.present? && record.period_end <= (current.period_end - 330.days) }
    end
    prior ||= records[4]

    return nil unless current && prior && prior.value.to_f.positive?

    ((current.value.to_f - prior.value.to_f) / prior.value.to_f).round(6)
  end

  def yield_change_30d_for(ticker, annualized_dividend, dividend_yield)
    return [nil, nil] unless dividend_yield.present?

    prior = TickerDividendSnapshot.for_ticker(ticker)
                                  .where('observed_at <= ?', @observed_at - 30.days)
                                  .order(observed_at: :desc)
                                  .first
    return [(dividend_yield.to_f - prior.dividend_yield.to_f).round(6), 'snapshot_30d'] if prior&.dividend_yield

    historical_price = historical_price_30d_for(ticker)
    return [nil, nil] unless annualized_dividend.to_f.positive? && historical_price.to_f.positive?

    prior_yield = (annualized_dividend.to_f / historical_price.to_f).round(6)
    [(dividend_yield.to_f - prior_yield).round(6), 'historical_price_30d']
  end

  def latest_metric_value(ticker, metric)
    TickerMetric.where(ticker: ticker, metric: metric)
                .order(period_end: :desc, observed_at: :desc)
                .limit(1)
                .pick(:value)
                &.to_f
  end

  def latest_price(ticker)
    row = latest_price_row(ticker)
    row&.price&.to_f
  end

  def latest_price_row(ticker)
    @latest_price_rows ||= {}
    @latest_price_rows[ticker] ||= PriceSample.where(ticker: ticker).order(sampled_at: :desc).first
  end

  def historical_price_30d_for(ticker)
    PriceSample.where(ticker: ticker)
               .where('sampled_at <= ?', @observed_at - 30.days)
               .order(sampled_at: :desc)
               .limit(1)
               .pick(:price)
               &.to_f
  end

  def upcoming_actions_by_ticker
    response = @broker_service.get_corporate_actions(
      symbols: @tickers,
      types: CORPORATE_ACTION_TYPES,
      start_date: @observed_at.to_date,
      end_date: (@observed_at + 6.months).to_date
    )
    return {} unless response[:success]

    Array(response[:actions]).each_with_object({}) do |action, memo|
      ticker = normalize_ticker(action[:symbol])
      next if ticker.blank?
      next if action[:ex_date].blank?

      current = memo[ticker]
      memo[ticker] = action if current.nil? || action[:ex_date] < current[:ex_date]
    end
  end

  def normalize_ticker(ticker)
    TickerNormalizer.normalize(ticker)
  end
end
