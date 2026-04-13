# frozen_string_literal: true

class DeskPerformanceDigestJob < ApplicationJob
  TIMEZONE_NAME = "Eastern Time (US & Canada)"

  queue_as :notifications

  def perform(now: Time.current)
    session_key = now.in_time_zone(TIMEZONE_NAME).strftime("%Y%m%d-%H")
    OutboxPublisherService.desk_performance_digest!(session_key: session_key)
    Rails.logger.info("[DeskPerformanceDigest] Published outbox event for slot #{session_key}")
  end
end
