# frozen_string_literal: true

module Dashboard
  class MarketStatusService
    # US Eastern Time market hours
    PRE_MARKET_START = AppConfig.market_pre_open_minutes
    MARKET_OPEN = AppConfig.market_open_minutes
    MARKET_CLOSE = AppConfig.market_close_minutes
    AFTER_HOURS_END = AppConfig.market_after_hours_end_minutes

    def self.current
      new.current
    end

    def current
      now = Time.current.in_time_zone("America/New_York")
      weekday = now.wday
      current_minutes = now.hour * 60 + now.min

      # Weekend
      if weekday == 0 || weekday == 6
        return { status: "CLOSED", reason: "Weekend" }
      end

      if current_minutes < PRE_MARKET_START
        { status: "CLOSED", reason: "Overnight" }
      elsif current_minutes < MARKET_OPEN
        { status: "PRE-MARKET", reason: "Pre-market trading" }
      elsif current_minutes < MARKET_CLOSE
        { status: "OPEN", reason: "Regular trading hours" }
      elsif current_minutes < AFTER_HOURS_END
        { status: "AFTER-HOURS", reason: "Extended hours" }
      else
        { status: "CLOSED", reason: "Market closed" }
      end
    end

    def self.status_for_trade(trade)
      return nil unless %w[EXECUTING PARTIALLY_FILLED].include?(trade.status)
      return nil if trade.alpaca_order_id.blank?
      return nil if trade.execution_started_at.blank?

      started_at = trade.execution_started_at.in_time_zone("America/New_York")
      weekday = started_at.wday
      current_minutes = started_at.hour * 60 + started_at.min

      if weekday == 0 || weekday == 6
        "weekend"
      elsif current_minutes < MARKET_OPEN
        "pre-market"
      elsif current_minutes >= MARKET_CLOSE
        "after-hours"
      else
        "market-hours"
      end
    end
  end
end
