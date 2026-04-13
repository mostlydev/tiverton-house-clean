# frozen_string_literal: true

# Discord configuration validation
# Ensures either bot token + channel IDs OR webhooks are configured

Rails.application.configure do
  config.after_initialize do
    # Check if Discord is configured (bot or webhook)
    bot_configured = AppConfig.discord_bot_token.present? &&
                     AppConfig.discord_trading_floor_channel_id.present?

    webhook_configured = AppConfig.discord_trading_floor_webhook.present?

    unless bot_configured || webhook_configured
      Rails.logger.warn(
        "[DISCORD] No Discord configuration found. " \
        "Set DISCORD_BOT_TOKEN + channel IDs OR webhook URLs in .env"
      )
    end

    if bot_configured
      Rails.logger.info(
        "[DISCORD] Bot configured: " \
        "trading_floor=#{AppConfig.discord_trading_floor_channel_id}, " \
        "infra=#{AppConfig.discord_infra_channel_id || 'not set'}"
      )
    elsif webhook_configured
      Rails.logger.info("[DISCORD] Webhook configured for trading_floor")
    end
  end
end
