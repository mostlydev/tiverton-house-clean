# frozen_string_literal: true

# Async Discord notification job
# Handles delivery of trade and system notifications to Discord
class DiscordNotificationJob < ApplicationJob
  queue_as :notifications
  sidekiq_options retry: 5
  # Use shared agent mention mapping from News::AgentMentions
  AGENT_DISCORD_IDS = News::AgentMentions.all

  # @param trade_id [Integer] Trade ID
  # @param event_type [Symbol] :filled, :partial, :failed, :approved, :denied, :passed, :cancelled,
  #   :stale_proposal, :timeout, :confirmed, :approval_needs_confirmation, :reconfirm_needed,
  #   :next_action_nudge
  # @param channel [Symbol] :trading_floor (default) or :infra
  def perform(trade_id, event_type, channel: :trading_floor)
    trade = Trade.includes(:agent).find(trade_id)
    message = format_message(trade, event_type)
    delivery_options = message_delivery_options(event_type)

    return unless NotificationDedupeService.allow?(dedupe_key(trade, event_type, channel),
                                                  ttl_seconds: AppConfig.discord_notification_dedupe_seconds)

    if channel == :infra
      DiscordService.post_to_infra(content: message, **delivery_options)
    else
      DiscordService.post_to_trading_floor(content: message, **delivery_options)
    end

    notify_infra_on_failure(trade, event_type, channel)
  rescue ActiveRecord::RecordNotFound
    Rails.logger.error("Trade not found for Discord notification: #{trade_id}")
  end

  private

  def format_message(trade, event_type)
    case event_type
    when :proposed
      format_actionable_trade_message("[PROPOSED]", trade, thesis_limit: 200)
    when :confirmed
      format_actionable_trade_message("[CONFIRMED]", trade)
    when :approved, :approval_needs_confirmation
      format_actionable_trade_message("[APPROVED]", trade, thesis_limit: 100)
    when :reconfirm_needed, :next_action_nudge
      format_actionable_trade_message("[FOLLOW UP]", trade)
    when :filled
      "[FILLED] #{trade.trade_id}\n" \
      "**#{trade.side} #{trade.qty_filled} #{trade.ticker} @ $#{trade.avg_fill_price}**\n" \
      "Agent: #{format_agent_line(trade)}"
    when :partial
      "[PARTIAL] #{trade.trade_id}\n" \
      "**#{trade.side} #{trade.qty_filled}/#{trade.qty_requested} #{trade.ticker} @ $#{trade.avg_fill_price}**\n" \
      "Agent: #{format_agent_id(trade)}"
    when :failed
      "[FAILED] #{trade.trade_id}\n" \
      "**#{trade.side} #{trade.ticker}**\n" \
      "Agent: #{format_agent_id(trade)}\n" \
      "Reason: #{trade.execution_error || 'Unknown'}\n" \
      "Next: #{format_agent_line(trade)} use propose_trade to re-propose with corrected params, or pass_trade to pass. " \
      "#{mention_or_id('tiverton')} review execution failure."
    when :denied
      "[DENIED] #{trade.trade_id}\n" \
      "**#{trade.side} #{format_qty(trade)} #{trade.ticker}**\n" \
      "Agent: #{format_agent_id(trade)}\n" \
      "Reason: #{trade.denial_reason || 'No reason provided'}\n" \
      "Next: #{format_agent_line(trade)} use propose_trade to revise and re-propose, or pass_trade to pass."
    when :passed
      "[PASSED] #{trade.trade_id}\n" \
      "**#{trade.side} #{format_qty(trade)} #{trade.ticker}**\n" \
      "Agent: #{format_agent_id(trade)}\n" \
      "Status: #{format_agent_line(trade)} passed after feedback."
    when :cancelled
      "[CANCELLED] #{trade.trade_id}\n" \
      "**#{trade.side} #{format_qty(trade)} #{trade.ticker}**\n" \
      "Agent: #{format_agent_id(trade)}\n" \
      "Reason: #{trade.denial_reason || 'User cancelled'}\n" \
      "Status: #{format_agent_line(trade)} cancellation recorded."
    when :stale_proposal
      "[CANCELLED - STALE PROPOSAL] #{trade.trade_id}\n" \
      "**#{trade.side} #{format_qty(trade)} #{trade.ticker}**\n" \
      "Agent: #{format_agent_id(trade)}\n" \
      "Attention: #{format_agent_line(trade)} proposal expired before decision.\n" \
      "Thesis: #{trade.thesis.to_s.truncate(120)}\n" \
      "If you still want this, use propose_trade with updated context."
    when :timeout
      "[TIMEOUT] #{trade.trade_id}\n" \
      "**#{trade.side} #{format_qty(trade)} #{trade.ticker}**\n" \
      "Agent: #{format_agent_id(trade)}\n" \
      "Reason: #{trade.execution_error || 'Execution timeout'}\n" \
      "Next: #{format_agent_line(trade)} use propose_trade to re-propose if still valid. " \
      "#{mention_or_id('tiverton')} review timeout."
    else
      "[#{event_type.to_s.upcase}] #{trade.trade_id}\n" \
      "**#{trade.side} #{trade.ticker}**\n" \
      "Agent: #{format_agent_id(trade)}"
    end
  end

  def format_actionable_trade_message(prefix, trade, thesis_limit: nil, mention_next_actor: true)
    lines = [
      "#{prefix} #{trade.trade_id}",
      "**#{trade.side} #{format_qty(trade)} #{trade.ticker}**",
      "Agent: #{format_agent_id(trade)}"
    ]

    if thesis_limit && trade.thesis.present?
      lines << "Thesis: #{trade.thesis.to_s.truncate(thesis_limit)}"
    end

    lines << next_action_line(trade, mention_actor: mention_next_actor)
    lines.join("\n")
  end

  def next_action_line(trade, mention_actor: true)
    next_action = Trades::NextActionService.new(trade).as_json

    if next_action[:actor].present?
      actor = if mention_actor
                format_next_action_actor(next_action[:actor], trade)
              else
                next_action[:actor].to_s
              end
      "Next: #{actor} #{next_action[:message]}"
    else
      "Status: #{next_action[:message]}"
    end
  end

  def format_next_action_actor(actor_id, trade)
    return mention_or_id("tiverton") if actor_id == "tiverton"
    return format_agent_line(trade) if actor_id == trade.agent.agent_id

    mention_or_id(actor_id)
  end

  def message_delivery_options(event_type)
    return {} unless [ :reconfirm_needed, :next_action_nudge ].include?(event_type)

    # Render explicit Discord mentions in reminder posts without notifying users.
    { allowed_mentions: { parse: [] } }
  end

  def format_agent_line(trade)
    agent_id = trade.agent.agent_id
    mention = mention_for(agent_id)
    return agent_id.to_s if mention.nil?

    "#{mention} (#{agent_id})"
  end

  def format_agent_id(trade)
    trade.agent.agent_id.to_s
  end

  def mention_for(agent_id)
    discord_id = AGENT_DISCORD_IDS[agent_id]
    return nil if discord_id.nil?

    "<@#{discord_id}>"
  end

  def mention_or_id(agent_id)
    mention_for(agent_id) || agent_id.to_s
  end

  def notify_infra_on_failure(trade, event_type, channel)
    return unless event_type == :failed
    return if channel == :infra

    DiscordService.post_to_infra(
      content: "[FAILED] #{trade.trade_id}\n" \
               "**#{trade.side} #{trade.ticker}**\n" \
               "Agent: #{format_agent_id(trade)}\n" \
               "Requester: #{format_agent_line(trade)}\n" \
               "Reason: #{trade.execution_error || 'Unknown'}\n" \
               "#{mention_or_id('tiverton')} how do you want to handle this?"
    )
  end

  def dedupe_key(trade, event_type, channel)
    "discord_notify:trade:#{trade.id}:#{event_type}:#{channel}"
  end

  def format_qty(trade)
    if trade.qty_requested.present? && trade.qty_requested > 0
      "#{trade.qty_requested}"
    elsif trade.amount_requested.present?
      "$#{trade.amount_requested}"
    else
      "?"
    end
  end
end
