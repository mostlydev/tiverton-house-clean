# frozen_string_literal: true

class NotificationDedupeService
  def self.allow?(key, ttl_seconds:)
    ttl = ttl_seconds.to_i
    return true if ttl <= 0

    return false if Rails.cache.read(key)

    Rails.cache.write(key, true, expires_in: ttl)
    true
  end
end
