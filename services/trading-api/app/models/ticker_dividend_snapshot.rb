# frozen_string_literal: true

class TickerDividendSnapshot < ApplicationRecord
  validates :ticker, presence: true
  validates :source, presence: true
  validates :observed_at, presence: true

  before_validation :normalize_fields

  scope :for_ticker, ->(ticker) { where(ticker: ticker.to_s.strip.upcase) }

  def self.latest_by_ticker(tickers: nil)
    scope = all
    scope = scope.where(ticker: Array(tickers)) if tickers.present?

    scope.select('DISTINCT ON (ticker) ticker_dividend_snapshots.*')
         .order('ticker, observed_at DESC')
  end

  private

  def normalize_fields
    self.ticker = ticker.to_s.strip.upcase if ticker.present?
    self.source = source.to_s.strip if source.present?
    self.meta = {} unless meta.is_a?(Hash)
  end
end
