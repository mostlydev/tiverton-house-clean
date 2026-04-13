class NewsDispatch < ApplicationRecord
  STATUSES = %w[pending awaiting_confirmation confirmed failed].freeze

  validates :batch_type, presence: true
  validates :status, inclusion: { in: STATUSES }
  validates :confirmation_token, presence: true, uniqueness: true
  validates :message, presence: true

  def confirmed?
    status == 'confirmed'
  end
end
