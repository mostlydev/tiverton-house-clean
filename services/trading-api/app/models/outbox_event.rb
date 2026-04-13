# frozen_string_literal: true

# Outbox event for exactly-once notification delivery.
# All notifications must go through the outbox to prevent duplicates.
class OutboxEvent < ApplicationRecord
  MAX_ATTEMPTS = AppConfig.outbox_max_attempts
  LOCK_TIMEOUT_MINUTES = AppConfig.outbox_lock_timeout_minutes

  validates :event_type, presence: true
  validates :aggregate_type, presence: true
  validates :aggregate_id, presence: true
  validates :scheduled_at, presence: true

  # Event types for trade lifecycle
  EVENT_TYPES = {
    trade_filled: "trade_filled",
    trade_partial_fill: "trade_partial_fill",
    trade_failed: "trade_failed",
    trade_canceled: "trade_canceled",
    trade_proposed: "trade_proposed",
    trade_approved: "trade_approved",
    trade_denied: "trade_denied",
    trade_passed: "trade_passed",
    trade_confirmed: "trade_confirmed",
    trade_confirmed_nudge: "trade_confirmed_nudge",
    trade_stale_proposal: "trade_stale_proposal",
    trade_reconfirm_needed: "trade_reconfirm_needed",
    trade_next_action_nudge: "trade_next_action_nudge",
    trade_timeout: "trade_timeout",
    remediation_alert: "remediation_alert",
    stop_loss_triggered: "stop_loss_triggered",
    desk_performance_digest: "desk_performance_digest"
  }.freeze

  enum :status, {
    pending: "pending",
    processing: "processing",
    completed: "completed",
    failed: "failed",
    dead_letter: "dead_letter"
  }, prefix: true

  scope :ready_to_process, -> {
    where(status: "pending")
      .where("scheduled_at <= ?", Time.current)
      .order(:scheduled_at)
  }

  scope :stale_locks, -> {
    where(status: "processing")
      .where("locked_at < ?", LOCK_TIMEOUT_MINUTES.minutes.ago)
  }

  # Publish an event to the outbox
  # Uses INSERT...ON CONFLICT to prevent duplicates
  def self.publish!(event_type:, aggregate_type:, aggregate_id:, sequence_key: nil, payload: {})
    event = new(
      event_type: event_type,
      aggregate_type: aggregate_type,
      aggregate_id: aggregate_id,
      sequence_key: sequence_key,
      payload: payload,
      scheduled_at: Time.current
    )

    # Try to create, or return existing if duplicate
    begin
      event.save!
      event
    rescue ActiveRecord::RecordNotUnique
      # Return the existing event (idempotent)
      find_by!(
        event_type: event_type,
        aggregate_type: aggregate_type,
        aggregate_id: aggregate_id,
        sequence_key: sequence_key
      )
    end
  end

  # Lock the event for processing
  def lock!(processor_id)
    return false unless status_pending?

    result = self.class.where(id: id, status: "pending").update_all(
      status: "processing",
      locked_by: processor_id,
      locked_at: Time.current,
      last_attempt_at: Time.current,
      attempts: attempts + 1
    )

    result > 0
  end

  # Mark as completed
  def complete!
    update!(
      status: "completed",
      processed_at: Time.current,
      locked_by: nil,
      locked_at: nil
    )
  end

  # Mark as failed with retry
  def fail_with_retry!(error_message)
    if attempts >= MAX_ATTEMPTS
      update!(
        status: "dead_letter",
        last_error: error_message,
        locked_by: nil,
        locked_at: nil
      )
    else
      # Exponential backoff: 2^attempts seconds
      next_attempt_at = Time.current + (2**attempts).seconds

      update!(
        status: "pending",
        last_error: error_message,
        scheduled_at: next_attempt_at,
        locked_by: nil,
        locked_at: nil
      )
    end
  end

  # Unlock stale events
  def self.unlock_stale!
    stale_locks.update_all(
      status: "pending",
      locked_by: nil,
      locked_at: nil
    )
  end
end
