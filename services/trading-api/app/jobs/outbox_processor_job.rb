# frozen_string_literal: true

# Processes outbox events and dispatches notifications.
# This is the single path for all trade lifecycle notifications.
class OutboxProcessorJob < ApplicationJob
  queue_as :default

  BATCH_SIZE = 50
  PROCESSOR_ID = "outbox-#{Socket.gethostname}-#{Process.pid}"

  def perform
    # First, unlock any stale events
    OutboxEvent.unlock_stale!

    # Process pending events
    events_processed = 0
    OutboxEvent.ready_to_process.limit(BATCH_SIZE).each do |event|
      next unless event.lock!(PROCESSOR_ID)

      begin
        process_event(event)
        event.complete!
        events_processed += 1
      rescue StandardError => e
        Rails.logger.error("Outbox event #{event.id} failed: #{e.message}")
        event.fail_with_retry!(e.message)
      end
    end

    Rails.logger.info("OutboxProcessor: processed #{events_processed} events") if events_processed > 0
  end

  private

  def process_event(event)
    case event.event_type
    when 'trade_filled'
      dispatch_trade_notification(event, :filled)
    when 'trade_partial_fill'
      dispatch_trade_notification(event, :partial)
    when 'trade_failed'
      dispatch_trade_notification(event, :failed)
    when 'trade_canceled'
      dispatch_trade_notification(event, :cancelled)
    when 'trade_proposed'
      dispatch_trade_notification(event, :proposed)
    when 'trade_approved'
      dispatch_trade_notification(event, :approved)
    when 'trade_denied'
      dispatch_trade_notification(event, :denied)
    when 'trade_passed'
      dispatch_trade_notification(event, :passed)
    when 'trade_confirmed'
      dispatch_trade_notification(event, :confirmed)
    when 'trade_stale_proposal'
      dispatch_trade_notification(event, :stale_proposal)
    when 'trade_confirmed_nudge', 'trade_reconfirm_needed', 'trade_next_action_nudge'
      dispatch_trade_notification(event, :next_action_nudge)
    when 'trade_timeout'
      dispatch_trade_notification(event, :timeout)
    when 'remediation_alert'
      dispatch_remediation_alert(event)
    when 'stop_loss_triggered'
      dispatch_stop_loss_notification(event)
    when 'desk_performance_digest'
      dispatch_desk_performance_digest
    else
      Rails.logger.warn("Unknown outbox event type: #{event.event_type}")
    end
  end

  def dispatch_trade_notification(event, notification_type)
    return if LedgerMigration.write_guard_enabled?

    trade_id = event.aggregate_id
    trade = Trade.find_by(id: trade_id)
    return unless trade

    # Delegate to existing DiscordNotificationJob
    DiscordNotificationJob.perform_now(trade.id, notification_type)
  end

  def dispatch_remediation_alert(event)
    # Remediation alerts should still go through even during migration
    payload = event.payload.with_indifferent_access

    Trades::RemediationAlertService.send_alert(
      alert_type: payload[:alert_type],
      message: payload[:message],
      context: payload[:context]
    )
  end

  def dispatch_stop_loss_notification(event)
    payload = event.payload.with_indifferent_access
    position_id = payload[:position_id] || event.aggregate_id
    return if position_id.blank?

    StopLossNotificationJob.perform_now(position_id, payload.to_h)
  end

  def dispatch_desk_performance_digest
    summary = Desk::PerformanceSummaryService.call
    message = Desk::PerformanceDigestFormatter.format(summary)
    DiscordService.post_to_trading_floor(content: message, allowed_mentions: { parse: [] })
    Rails.logger.info("[DeskPerformanceDigest] Posted digest to #trading-floor")
  end
end
