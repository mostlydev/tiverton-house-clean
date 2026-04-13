# frozen_string_literal: true

class TickerMetric < ApplicationRecord
  validates :ticker, presence: true
  validates :metric, presence: true
  validates :value, presence: true, numericality: true
  validates :observed_at, presence: true
  validates :source, presence: true

  before_validation :normalize_fields

  scope :for_ticker, ->(ticker) { where(ticker: ticker) }

  def self.latest_for(ticker:, metrics: nil, sources: nil, period_type: nil)
    scope = for_ticker(ticker)
    scope = scope.where(metric: metrics) if metrics.present?
    scope = scope.where(source: sources) if sources.present?
    scope = scope.where(period_type: period_type) if period_type.present?

    if sources.present?
      scope.select('DISTINCT ON (metric, source) ticker_metrics.*')
           .order('metric, source, period_end DESC NULLS LAST, observed_at DESC')
    else
      scope.select('DISTINCT ON (metric) ticker_metrics.*')
           .order('metric, period_end DESC NULLS LAST, observed_at DESC')
    end
  end

  def self.latest_by_ticker(metric:, source: nil)
    scope = where(metric: metric)
    scope = scope.where(source: source) if source.present?

    scope.select('DISTINCT ON (ticker) ticker_metrics.*')
         .order('ticker, observed_at DESC')
  end

  def self.history_for(ticker:, metrics: nil, sources: nil, period_type: nil, limit: 8)
    scope = for_ticker(ticker)
    scope = scope.where(metric: metrics) if metrics.present?
    scope = scope.where(source: sources) if sources.present?
    scope = scope.where(period_type: period_type) if period_type.present?

    scope.order('metric, period_end DESC NULLS LAST, observed_at DESC').limit(limit)
  end

  def ttl_seconds
    AppConfig.ticker_metrics_ttl_seconds(metric)
  end

  def fresh?(reference_time = Time.current)
    return false if observed_at.blank?

    (reference_time - observed_at) <= ttl_seconds
  end

  private

  def normalize_fields
    self.ticker = ticker.to_s.strip.upcase if ticker.present?
    self.metric = metric.to_s.strip.downcase if metric.present?
    self.source = source.to_s.strip if source.present?
    self.period_type = period_type.to_s.strip.downcase if period_type.present?
  end
end
