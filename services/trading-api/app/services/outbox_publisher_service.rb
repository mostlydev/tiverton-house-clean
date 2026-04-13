# frozen_string_literal: true

# Publishes events to the outbox for exactly-once delivery.
# This service should replace all direct DiscordNotificationJob calls.
class OutboxPublisherService
  class << self
    # Publish a trade fill event
    def trade_filled!(trade, fill_id: nil)
      OutboxEvent.publish!(
        event_type: 'trade_filled',
        aggregate_type: 'Trade',
        aggregate_id: trade.id,
        sequence_key: fill_id || fill_sequence_key(trade),
        payload: build_trade_payload(trade)
      )
    end

    # Publish a partial fill event
    def trade_partial_fill!(trade, fill_id: nil)
      OutboxEvent.publish!(
        event_type: 'trade_partial_fill',
        aggregate_type: 'Trade',
        aggregate_id: trade.id,
        sequence_key: fill_id || "partial-#{trade.id}-#{trade.qty_filled}",
        payload: build_trade_payload(trade)
      )
    end

    # Publish a trade failed event
    def trade_failed!(trade)
      OutboxEvent.publish!(
        event_type: 'trade_failed',
        aggregate_type: 'Trade',
        aggregate_id: trade.id,
        sequence_key: "failed-#{trade.id}",
        payload: build_trade_payload(trade)
      )
    end

    # Publish a trade canceled event
    def trade_canceled!(trade)
      OutboxEvent.publish!(
        event_type: 'trade_canceled',
        aggregate_type: 'Trade',
        aggregate_id: trade.id,
        sequence_key: "canceled-#{trade.id}",
        payload: build_trade_payload(trade)
      )
    end

    # Publish a trade proposed event
    def trade_proposed!(trade)
      OutboxEvent.publish!(
        event_type: 'trade_proposed',
        aggregate_type: 'Trade',
        aggregate_id: trade.id,
        sequence_key: "proposed-#{trade.id}",
        payload: build_trade_payload(trade)
      )
    end

    # Publish a trade approved event
    def trade_approved!(trade)
      OutboxEvent.publish!(
        event_type: 'trade_approved',
        aggregate_type: 'Trade',
        aggregate_id: trade.id,
        sequence_key: "approved-#{trade.id}",
        payload: build_trade_payload(trade)
      )
    end

    # Publish a trade denied event
    def trade_denied!(trade)
      OutboxEvent.publish!(
        event_type: 'trade_denied',
        aggregate_type: 'Trade',
        aggregate_id: trade.id,
        sequence_key: "denied-#{trade.id}",
        payload: build_trade_payload(trade)
      )
    end

    # Publish a trade passed event
    def trade_passed!(trade)
      OutboxEvent.publish!(
        event_type: 'trade_passed',
        aggregate_type: 'Trade',
        aggregate_id: trade.id,
        sequence_key: "passed-#{trade.id}",
        payload: build_trade_payload(trade)
      )
    end

    # Publish a trade confirmed event
    def trade_confirmed!(trade)
      OutboxEvent.publish!(
        event_type: 'trade_confirmed',
        aggregate_type: 'Trade',
        aggregate_id: trade.id,
        sequence_key: "confirmed-#{trade.id}",
        payload: build_trade_payload(trade)
      )
    end

    # Publish a confirmed nudge (rate-limited to one per 5-min window)
    def trade_confirmed_nudge!(trade)
      OutboxEvent.publish!(
        event_type: 'trade_confirmed_nudge',
        aggregate_type: 'Trade',
        aggregate_id: trade.id,
        sequence_key: "confirmed-nudge-#{trade.id}-#{Time.current.to_i / 300}",
        payload: build_trade_payload(trade)
      )
    end

    # Publish a stale proposal event
    def trade_stale_proposal!(trade)
      OutboxEvent.publish!(
        event_type: 'trade_stale_proposal',
        aggregate_type: 'Trade',
        aggregate_id: trade.id,
        sequence_key: "stale-proposal-#{trade.id}",
        payload: build_trade_payload(trade)
      )
    end

    # Publish a reconfirm needed event (rate-limited to one per 5-min window)
    def trade_reconfirm_needed!(trade)
      OutboxEvent.publish!(
        event_type: 'trade_reconfirm_needed',
        aggregate_type: 'Trade',
        aggregate_id: trade.id,
        sequence_key: "reconfirm-#{trade.id}-#{Time.current.to_i / 300}",
        payload: build_trade_payload(trade)
      )
    end

    # Publish a generic next-action nudge event (rate-limited to one per 5-min window)
    def trade_next_action_nudge!(trade)
      OutboxEvent.publish!(
        event_type: 'trade_next_action_nudge',
        aggregate_type: 'Trade',
        aggregate_id: trade.id,
        sequence_key: "next-action-#{trade.id}-#{Time.current.to_i / 300}",
        payload: build_trade_payload(trade)
      )
    end

    # Publish a trade timeout event
    def trade_timeout!(trade)
      OutboxEvent.publish!(
        event_type: 'trade_timeout',
        aggregate_type: 'Trade',
        aggregate_id: trade.id,
        sequence_key: "timeout-#{trade.id}",
        payload: build_trade_payload(trade)
      )
    end

    # Publish a remediation alert
    def remediation_alert!(alert_type:, message:, context: {})
      # Use a hash of the alert for deduplication within a short window
      alert_key = Digest::SHA256.hexdigest("#{alert_type}:#{message}:#{context.to_json}")[0..15]

      OutboxEvent.publish!(
        event_type: 'remediation_alert',
        aggregate_type: 'System',
        aggregate_id: 0,
        sequence_key: "alert-#{Time.current.strftime('%Y%m%d%H%M')}-#{alert_key}",
        payload: {
          alert_type: alert_type,
          message: message,
          context: context
        }
      )
    end

    # Publish a stop-loss alert for a position.
    # Repeats are deduped by reminder window bucket.
    def stop_loss_triggered!(position:, current_price:, reminder_bucket:)
      OutboxEvent.publish!(
        event_type: 'stop_loss_triggered',
        aggregate_type: 'Position',
        aggregate_id: position.id,
        sequence_key: "stop-loss-#{position.id}-#{reminder_bucket}",
        payload: {
          position_id: position.id,
          agent_id: position.agent.agent_id,
          ticker: position.ticker,
          qty: position.qty.to_f,
          stop_loss: position.stop_loss.to_f,
          current_price: current_price.to_f,
          alert_count: position.stop_loss_alert_count.to_i + 1
        }
      )
    end

    def desk_performance_digest!(session_key:)
      OutboxEvent.publish!(
        event_type: 'desk_performance_digest',
        aggregate_type: 'System',
        aggregate_id: 0,
        sequence_key: "perf-digest-#{session_key}",
        payload: {}
      )
    end

    private

    def fill_sequence_key(trade)
      [
        "fill",
        trade.id,
        trade.execution_completed_at&.utc&.iso8601(6) || "unknown",
        normalized_numeric(trade.qty_filled),
        normalized_numeric(trade.avg_fill_price)
      ].join(":")
    end

    def normalized_numeric(value)
      return "nil" if value.nil?

      BigDecimal(value.to_s).to_s("F")
    rescue ArgumentError, TypeError
      value.to_s
    end

    def build_trade_payload(trade)
      {
        trade_id: trade.trade_id,
        agent_id: trade.agent&.agent_id,
        ticker: trade.ticker,
        side: trade.side,
        status: trade.status,
        qty_requested: trade.qty_requested,
        qty_filled: trade.qty_filled,
        avg_fill_price: trade.avg_fill_price,
        filled_value: trade.filled_value
      }
    end
  end
end
