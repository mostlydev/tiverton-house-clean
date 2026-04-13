class ResearchNote < ApplicationRecord
  NOTE_TYPES = %w[finding risk_flag thesis_change profit_signal catalyst].freeze

  belongs_to :notable, polymorphic: true

  validates :note_type, presence: true, inclusion: { in: NOTE_TYPES }
  validates :content, presence: true
end
