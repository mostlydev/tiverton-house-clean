class Investigation < ApplicationRecord
  STATUSES = %w[active paused completed].freeze

  has_many :investigation_entities, dependent: :destroy
  has_many :research_entities, through: :investigation_entities
  has_many :research_notes, as: :notable, dependent: :destroy

  validates :title, presence: true
  validates :status, presence: true, inclusion: { in: STATUSES }

  scope :active, -> { where(status: 'active') }
  scope :completed, -> { where(status: 'completed') }
end
