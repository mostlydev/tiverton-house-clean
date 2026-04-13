class NewsSummary < ApplicationRecord
  validates :summary_type, presence: true
  validates :body, presence: true
end
