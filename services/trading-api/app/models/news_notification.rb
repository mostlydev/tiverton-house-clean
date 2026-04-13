class NewsNotification < ApplicationRecord
  belongs_to :agent

  validates :symbol, presence: true
  validates :notified_at, presence: true

  before_validation :normalize_symbol

  private

  def normalize_symbol
    self.symbol = symbol.to_s.strip.upcase if symbol
  end
end
