class PriceSample < ApplicationRecord
  validates :ticker, presence: true
  validates :price, presence: true
  validates :sampled_at, presence: true
  validates :sample_minute, presence: true

  before_validation :normalize_ticker

  private

  def normalize_ticker
    self.ticker = ticker.to_s.strip.upcase if ticker
  end
end
