# frozen_string_literal: true

module Trades
  class StaleTradeService
    EXECUTION_TIMEOUT = AppConfig.trades_stale_execution_timeout
    APPROVAL_TIMEOUT = AppConfig.trades_stale_approval_timeout
    PROPOSAL_TIMEOUT = AppConfig.trades_stale_proposal_timeout

    def call
      cancel_stale_proposals
      timeout_stale_executions
      nudge_pending_approvals
      request_reconfirmation
    end

    # Cancel PROPOSED trades older than threshold
    def cancel_stale_proposals
      stale_proposals = Trade.where(status: "PROPOSED")
                             .where("created_at < ?", PROPOSAL_TIMEOUT.ago)

      Rails.logger.info("Found #{stale_proposals.count} stale proposals to cancel")

      stale_proposals.each do |trade|
        if stop_loss_auto_approve?(trade)
          auto_approve_stop_loss!(trade, reason: "stale_proposal")
          next
        end

        cancel_stale_proposal(trade)
      end
    end

    # Timeout EXECUTING trades without order ID that are > 5 min old
    def timeout_stale_executions
      stale_executions = Trade.where(status: "EXECUTING")
                             .where(alpaca_order_id: nil)
                             .where("updated_at < ?", EXECUTION_TIMEOUT.ago)

      Rails.logger.info("Found #{stale_executions.count} stale executions to timeout")

      stale_executions.each do |trade|
        timeout_trade(trade)
      end
    end

    # Nudge confirmation for approved/queued trades > 5 min old without confirmed_at.
    # Timer resets on approval action because approved_at is updated at approval time.
    def request_reconfirmation
      stale_approvals = Trade.where(status: [ "APPROVED", "QUEUED" ])
                            .where(confirmed_at: nil)
                            .where("approved_at < ?", APPROVAL_TIMEOUT.ago)

      Rails.logger.info("Found #{stale_approvals.count} stale approvals needing reconfirmation")

      stale_approvals.each do |trade|
        request_reconfirmation_for(trade)
      end
    end

    # Nudge approval for proposed/pending trades older than timeout with approval still missing.
    # Timer resets when trader confirms because reference switches from created_at to confirmed_at.
    def nudge_pending_approvals
      stale_pending_approval = Trade.where(status: [ "PROPOSED", "PENDING" ])
                                    .where(approved_at: nil)
                                    .where("COALESCE(confirmed_at, created_at) < ?", APPROVAL_TIMEOUT.ago)

      Rails.logger.info("Found #{stale_pending_approval.count} trades pending approval action")

      stale_pending_approval.each do |trade|
        if stop_loss_auto_approve?(trade)
          reason = trade.confirmed_at.present? ? "stale_confirmed" : "stale_proposal_nudge"
          auto_approve_stop_loss!(trade, reason: reason)
        else
          nudge_next_action_for(
            trade,
            event_type: "APPROVAL_NUDGE",
            details: {
              confirmed_at: trade.confirmed_at,
              created_at: trade.created_at,
              timeout: APPROVAL_TIMEOUT.to_i
            }
          )
        end
      end
    end

    private

    def timeout_trade(trade)
      Rails.logger.warn("Timing out stale execution: #{trade.trade_id} (#{EXECUTION_TIMEOUT} without order ID)")

      trade.execution_error = "Execution timeout: no order ID after #{EXECUTION_TIMEOUT}"
      trade.fail!

      # Notify via outbox
      OutboxPublisherService.trade_timeout!(trade)

      # Log event
      TradeEvent.create!(
        trade: trade,
        event_type: "TIMEOUT",
        actor: "system",
        details: { reason: "Execution timeout", timeout: EXECUTION_TIMEOUT.to_i }.to_json
      )
    end

    def cancel_stale_proposal(trade)
      Rails.logger.info("Cancelling stale proposal: #{trade.trade_id} (#{PROPOSAL_TIMEOUT} old)")

      trade.denial_reason = "STALE_PROPOSAL"
      trade.cancel!

      OutboxPublisherService.trade_stale_proposal!(trade)

      TradeEvent.create!(
        trade: trade,
        event_type: "STALE_PROPOSAL",
        actor: "system",
        details: { reason: "Proposal timeout", timeout: PROPOSAL_TIMEOUT.to_i }
      )
    end

    def request_reconfirmation_for(trade)
      Rails.logger.info("Requesting reconfirmation for #{trade.trade_id} (approved #{time_ago(trade.approved_at)})")

      nudge_next_action_for(
        trade,
        event_type: "RECONFIRMATION_REQUESTED",
        details: {
          approved_at: trade.approved_at,
          status: trade.status,
          timeout: APPROVAL_TIMEOUT.to_i
        }
      )
    end

    def nudge_next_action_for(trade, event_type:, details:)
      OutboxPublisherService.trade_next_action_nudge!(trade)

      TradeEvent.create!(
        trade: trade,
        event_type: event_type,
        actor: "system",
        details: details.to_json
      )
    end

    def stop_loss_auto_approve?(trade)
      trade.stop_loss_exit? && trade.side == "SELL"
    end

    def auto_approve_stop_loss!(trade, reason:)
      trade.confirmed_at ||= Time.current
      return unless trade.may_approve?

      Rails.logger.info("Auto-approving stop-loss trade #{trade.trade_id} (#{reason})")

      trade.approved_by = "system_stop_loss"
      trade.approve!

      TradeEvent.create!(
        trade: trade,
        event_type: "STOP_LOSS_AUTO_APPROVED",
        actor: "system",
        details: { reason: reason, confirmed_at: trade.confirmed_at }.to_json
      )
    end

    def time_ago(time)
      return "unknown" unless time

      seconds = (Time.current - time).to_i
      minutes = seconds / 60

      "#{minutes} minutes ago"
    end
  end
end
