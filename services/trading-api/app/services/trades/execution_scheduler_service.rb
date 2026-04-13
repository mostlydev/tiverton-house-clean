# frozen_string_literal: true

module Trades
  class ExecutionSchedulerService
    def initialize(trade, now: Time.current)
      @trade = trade
      @now = now
      @session = MarketSessionService.current(at: now)
    end

    def call
      return unless @trade.APPROVED? || @trade.QUEUED?
      return unless @trade.confirmed_at.present?

      if crypto_like?(@trade.asset_class)
        execute_now!(extended_hours: false)
        return
      end

      decision = equity_decision
      case decision[:action]
      when :execute
        execute_now!(extended_hours: decision[:extended_hours])
      when :queue
        queue_trade!(scheduled_for: decision[:scheduled_for], extended_hours: decision[:extended_hours], reason: decision[:reason])
      end
    end

    private

    def equity_decision
      if @trade.asset_class == "us_option"
        return queue_for_regular(reason: "options_regular_hours_only") unless @session.regular?
        return { action: :execute, extended_hours: false }
      end

      if @session.regular?
        return { action: :execute, extended_hours: false }
      end

      if @session.extended?
        return queue_for_regular(reason: "options_extended_disallowed") if @trade.asset_class == "us_option"
        if can_extended_order? && policy_allows_extended_now?
          return { action: :execute, extended_hours: true }
        end
        return queue_for_regular(reason: "extended_session_disallowed_order_type")
      end

      case @trade.execution_policy
      when "allow_extended"
        if can_extended_order?
          return queue_for_extended(reason: "market_closed_allow_extended")
        end
        queue_for_regular(reason: "market_closed_no_extended_order")
      when "queue_until_open"
        queue_for_regular(reason: "market_closed_queue_until_open")
      when "immediate"
        queue_for_regular(reason: "market_closed_immediate")
      else
        queue_for_regular(reason: "market_closed_default")
      end
    end

    def queue_for_regular(reason:)
      { action: :queue, scheduled_for: @session.next_regular_open_at, extended_hours: false, reason: reason }
    end

    def queue_for_extended(reason:)
      { action: :queue, scheduled_for: @session.next_extended_open_at, extended_hours: true, reason: reason }
    end

    def policy_allows_extended_now?
      %w[allow_extended immediate].include?(@trade.execution_policy)
    end

    def can_extended_order?
      order_type == "LIMIT" && @trade.limit_price.present?
    end

    def order_type
      @trade.order_type.to_s.upcase
    end

    def crypto_like?(asset_class)
      %w[crypto crypto_perp].include?(asset_class)
    end

    def execute_now!(extended_hours:)
      @trade.with_lock do
        @trade.reload
        return unless @trade.APPROVED? || @trade.QUEUED?

        if @trade.QUEUED?
          @trade.release!
        end

        @trade.extended_hours = extended_hours
        @trade.scheduled_for = nil
        @trade.save!
      end

      TradeExecutionJob.perform_later(@trade.id)
    end

    def queue_trade!(scheduled_for:, extended_hours:, reason:)
      @trade.with_lock do
        @trade.reload
        return unless @trade.APPROVED? || @trade.QUEUED?

        @trade.extended_hours = extended_hours
        @trade.scheduled_for = scheduled_for

        if @trade.APPROVED?
          @trade.queue!
        else
          @trade.queued_at ||= Time.current
          @trade.save!
        end
      end

      Rails.logger.info(
        "Queued trade #{@trade.trade_id} for #{scheduled_for} (policy=#{@trade.execution_policy}, reason=#{reason})"
      )
    end
  end
end
