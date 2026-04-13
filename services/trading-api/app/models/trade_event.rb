class TradeEvent < ApplicationRecord
  belongs_to :trade

  # Validations
  validates :event_type, presence: true
  validates :actor, presence: true

  # Scopes
  scope :recent, -> { order(created_at: :desc) }
  scope :by_trade, ->(trade_id) { where(trade_id: trade_id) }

  # Instance methods
  def to_s
    "#{event_type} by #{actor} at #{created_at}"
  end
end
