# frozen_string_literal: true

# Immutable status transitions for broker orders.
class BrokerOrderEvent < ApplicationRecord
  belongs_to :broker_order

  validates :event_type, presence: true
  validates :broker_event_ts, presence: true

  scope :by_sequence, -> { order(:broker_event_ts, :event_seq) }
end
