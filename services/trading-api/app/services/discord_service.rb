# frozen_string_literal: true

# Discord notification service
# Supports both Discord bot (via REST API) and webhooks
#
# Configuration (.env):
#   DISCORD_BOT_TOKEN - Bot token from Discord Developer Portal
#   DISCORD_TRADING_FLOOR_CHANNEL_ID - Channel ID for trade notifications
#   DISCORD_INFRA_CHANNEL_ID - Channel ID for system/infra notifications
#
# Or use webhooks (simpler, but less flexible):
#   DISCORD_TRADING_FLOOR_WEBHOOK - Webhook URL for trading floor
#   DISCORD_INFRA_WEBHOOK - Webhook URL for infra channel

class DiscordService
  DISCORD_API_BASE = "https://discord.com/api/v10"

  class << self
    # Post message to #trading-floor channel
    def post_to_trading_floor(content:, embed: nil, allowed_mentions: nil)
      post_message(
        channel: :trading_floor,
        content: content,
        embed: embed,
        allowed_mentions: allowed_mentions
      )
    end

    # Post message to #infra channel
    def post_to_infra(content:, embed: nil, allowed_mentions: nil)
      post_message(
        channel: :infra,
        content: content,
        embed: embed,
        allowed_mentions: allowed_mentions
      )
    end

    private

    def post_message(channel:, content:, embed: nil, allowed_mentions: nil)
      # Choose webhook or bot approach
      webhook_url = webhook_for(channel)
      if webhook_url.present?
        post_via_webhook(webhook_url, content, embed, allowed_mentions)
      else
        post_via_bot(channel, content, embed, allowed_mentions)
      end
    rescue => e
      Rails.logger.error("Discord delivery failed (#{channel}): #{e.message}")
      false
    end

    def post_via_webhook(webhook_url, content, embed, allowed_mentions)
      payload = {
        content: content,
        username: "Leviathan"
      }
      payload[:embeds] = [ embed ] if embed
      payload[:allowed_mentions] = allowed_mentions if allowed_mentions

      response = Faraday.post(webhook_url) do |req|
        req.headers["Content-Type"] = "application/json"
        req.body = payload.to_json
      end

      response.success?
    end

    def post_via_bot(channel, content, embed, allowed_mentions)
      channel_id = channel_id_for(channel)
      return false unless channel_id.present?

      bot_token = AppConfig.discord_bot_token
      return false unless bot_token.present?

      payload = { content: content }
      payload[:embeds] = [ embed ] if embed
      payload[:allowed_mentions] = allowed_mentions if allowed_mentions

      response = Faraday.post("#{DISCORD_API_BASE}/channels/#{channel_id}/messages") do |req|
        req.headers["Authorization"] = "Bot #{bot_token}"
        req.headers["Content-Type"] = "application/json"
        req.body = payload.to_json
      end

      response.success?
    end

    def webhook_for(channel)
      case channel
      when :trading_floor
        AppConfig.discord_trading_floor_webhook
      when :infra
        AppConfig.discord_infra_webhook
      end
    end

    def channel_id_for(channel)
      case channel
      when :trading_floor
        AppConfig.discord_trading_floor_channel_id
      when :infra
        AppConfig.discord_infra_channel_id
      end
    end
  end
end
