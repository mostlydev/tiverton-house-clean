class NewsSymbol < ApplicationRecord
  belongs_to :news_article

  validates :symbol, presence: true

  before_validation :normalize_symbol

  private

  def normalize_symbol
    self.symbol = symbol.to_s.strip.upcase if symbol
  end
end
