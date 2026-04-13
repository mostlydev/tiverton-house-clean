# frozen_string_literal: true

# Sends repeated stop-loss hit reminders to the trade owner.
class StopLossNotificationJob < ApplicationJob
  queue_as :notifications
  sidekiq_options retry: 5

  AGENT_DISCORD_IDS = News::AgentMentions.all

  def perform(position_id, payload = {})
    position = Position.includes(:agent).find(position_id)
    payload = payload.with_indifferent_access

    agent_id = position.agent.agent_id
    current_price = payload[:current_price].presence || infer_current_price(position)
    alert_count = payload[:alert_count].to_i
    comparator = position.qty.to_f.negative? ? '>=' : '<='

    message = [
      "[STOP LOSS HIT] #{position.ticker}",
      "Agent: #{format_agent(agent_id)}",
      "**Price $#{format_price(current_price)} #{comparator} Stop $#{format_price(position.stop_loss)}**",
      "Qty: #{position.qty.to_f}",
      "Reminder: ##{[alert_count, 1].max}",
      "Action: review and submit exit/defensive trade now."
    ].join("\n")

    return unless NotificationDedupeService.allow?(dedupe_key(position, alert_count),
                                                  ttl_seconds: AppConfig.discord_notification_dedupe_seconds)

    DiscordService.post_to_trading_floor(content: message)
  rescue ActiveRecord::RecordNotFound
    Rails.logger.warn("StopLossNotificationJob: position not found #{position_id}")
  end

  private

  def format_agent(agent_id)
    discord_id = AGENT_DISCORD_IDS[agent_id.to_s]
    return agent_id.to_s if discord_id.blank?

    "<@#{discord_id}> (#{agent_id})"
  end

  def dedupe_key(position, alert_count)
    "discord_notify:stop_loss:#{position.id}:#{alert_count.to_i}"
  end

  def infer_current_price(position)
    return nil if position.qty.to_f.zero?

    position.current_value.to_f / position.qty.to_f
  end

  def format_price(value)
    format('%.4f', value.to_f)
  end
end
