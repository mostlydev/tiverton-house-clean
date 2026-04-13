# frozen_string_literal: true

module Dashboard
  class TradingFloorService
    DISCORD_API_BASE = "https://discord.com/api/v10"
    WINDOW_HOURS = 24
    MAX_ITEMS = 20
    CACHE_TTL = 60 # seconds

    def self.recent_feed
      new.recent_feed
    end

    def recent_feed
      return unavailable unless configured?

      items = fetch_messages
      cutoff = WINDOW_HOURS.hours.ago
      items = items.select { |item| item[:timestamp] > cutoff }
      items = items.last(MAX_ITEMS)

      {
        available: items.any?,
        items: items,
        count: items.size,
        window_hours: WINDOW_HOURS
      }
    rescue => e
      Rails.logger.error("[TradingFloor] Discord fetch failed: #{e.message}")
      unavailable
    end

    private

    def configured?
      bot_token.present? && channel_id.present?
    end

    def bot_token
      AppConfig.discord_bot_token
    end

    def channel_id
      AppConfig.discord_trading_floor_channel_id
    end

    def fetch_messages
      cached = Rails.cache.read("trading_floor:messages")
      return cached if cached

      response = Faraday.get(
        "#{DISCORD_API_BASE}/channels/#{channel_id}/messages",
        { limit: 50 },
        {
          "Authorization" => "Bot #{bot_token}",
          "Content-Type" => "application/json"
        }
      )

      unless response.success?
        Rails.logger.warn("[TradingFloor] Discord API returned #{response.status}")
        return []
      end

      raw = JSON.parse(response.body)
      return [] unless raw.is_a?(Array)

      # Discord returns newest first — reverse for chronological order
      items = raw.reverse.filter_map { |msg| parse_message(msg) }

      Rails.cache.write("trading_floor:messages", items, expires_in: CACHE_TTL)
      items
    end

    def parse_message(msg)
      timestamp = Time.parse(msg["timestamp"]) rescue nil
      return nil unless timestamp

      author = msg.dig("author", "global_name") ||
               msg.dig("author", "username") ||
               "unknown"

      content = msg["content"].to_s
      return nil if content.blank?

      {
        id: msg["id"],
        ts_iso: timestamp.iso8601,
        ts: timestamp.strftime("%H:%M:%S"),
        channel_id: channel_id,
        author: author,
        msg: content,
        timestamp: timestamp
      }
    end

    def unavailable
      {
        available: false,
        items: [],
        count: 0,
        window_hours: WINDOW_HOURS
      }
    end
  end
end
