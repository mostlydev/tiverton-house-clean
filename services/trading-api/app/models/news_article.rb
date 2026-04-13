class NewsArticle < ApplicationRecord
  has_many :news_symbols, dependent: :destroy

  validates :external_id, presence: true, uniqueness: true

  before_validation :normalize_external_id

  scope :recent_first, -> { order(published_at: :desc, created_at: :desc) }

  def symbols
    news_symbols.pluck(:symbol)
  end

  def content_or_summary
    content.presence || summary.presence || ""
  end

  private

  def normalize_external_id
    self.external_id = external_id.to_s.strip if external_id
  end
end
