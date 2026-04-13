# frozen_string_literal: true

module Trades
  class NextActionService
    def initialize(trade)
      @trade = trade
    end

    def as_json(*)
      {
        actor: actor,
        action: action,
        message: message,
        approval_missing: approval_missing?,
        confirmation_missing: confirmation_missing?,
        complete: actor.nil?
      }
    end

    private

    def approval_missing?
      @trade.approved_at.blank?
    end

    def confirmation_missing?
      @trade.confirmed_at.blank?
    end

    def actor
      return "tiverton" if approval_missing?
      return @trade.agent.agent_id if confirmation_missing?

      nil
    end

    def action
      return "advise" if approval_missing? && confirmation_missing?
      return "approve" if approval_missing?
      return "confirm" if confirmation_missing?

      nil
    end

    def message
      if approval_missing? && confirmation_missing?
        "This trade is proposed. Tiverton: give advisory feedback in Discord mentioning the proposing trader by <@DISCORD_ID>, then run the compliance check and use the approve_trade or deny_trade tool. Trader: use the confirm_trade tool when ready. Both are needed before execution."
      elsif approval_missing?
        "Trader has confirmed. Tiverton: run the mechanical compliance check and use the approve_trade tool if hard limits pass, otherwise use deny_trade with the specific rule breach."
      elsif confirmation_missing?
        "Compliance approved. Trader: use the confirm_trade tool for trade #{@trade.trade_id} to proceed."
      else
        completion_message
      end
    end

    def completion_message
      case @trade.status
      when "APPROVED"
        "Approval and confirmation complete; execution is scheduled automatically."
      when "QUEUED"
        "Approval and confirmation complete; queued for the next eligible market session."
      when "EXECUTING"
        "Approval and confirmation complete; executing now."
      else
        @trade.status.to_s
      end
    end
  end
end
