# frozen_string_literal: true

class TradeExecutionJob < ApplicationJob
  queue_as :default

  # Retry up to 3 times with exponential backoff
  retry_on StandardError, wait: :exponentially_longer, attempts: 3

  def perform(trade_id)
    trade = Trade.find(trade_id)
    return unless trade.can_execute?

    TradeExecutionService.new(trade, executed_by: "sentinel").call
  end
end
