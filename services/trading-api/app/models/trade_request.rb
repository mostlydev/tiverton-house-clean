# frozen_string_literal: true

# Records each external trade submission attempt for idempotency.
# Prevents duplicate proposals from context drift or retries.
class TradeRequest < ApplicationRecord
  belongs_to :agent, optional: true
  belongs_to :trade, optional: true

  validates :request_id, presence: true, uniqueness: true
  validates :source, presence: true

  enum :status, {
    accepted: 'accepted',
    duplicate: 'duplicate',
    rejected: 'rejected'
  }, prefix: true

  scope :accepted, -> { where(status: 'accepted') }
  scope :duplicates, -> { where(status: 'duplicate') }
end
