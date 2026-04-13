class Watchlist < ApplicationRecord
  belongs_to :agent

  validates :ticker, presence: true
  validates :source, presence: true

  before_validation :normalize_ticker

  private

  def normalize_ticker
    self.ticker = ticker.to_s.strip.upcase if ticker
  end
end
