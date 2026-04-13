# frozen_string_literal: true

class BrokerAccountSnapshot < ApplicationRecord
  validates :broker, presence: true
  validates :fetched_at, presence: true

  scope :recent_first, -> { order(fetched_at: :desc) }

  def self.latest(broker: 'alpaca')
    where(broker: broker).recent_first.limit(1).first
  end

  def self.stale?(max_age_seconds: 60, broker: 'alpaca')
    snapshot = latest(broker: broker)
    return true unless snapshot&.fetched_at

    snapshot.fetched_at < Time.current - max_age_seconds
  end
end
