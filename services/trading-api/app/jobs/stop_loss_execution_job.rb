# frozen_string_literal: true

# Async wrapper for StopLossExecutionService.
# Enqueued by PriceUpdateService when a stop loss is hit.
# Runs the full create-approve-execute flow without blocking the price update loop.
class StopLossExecutionJob < ApplicationJob
  queue_as :default
  sidekiq_options retry: 0 # Do not retry — duplicates are dangerous for market orders

  def perform(position_id, current_price)
    position = Position.includes(:agent).find(position_id)

    unless position.agent
      Rails.logger.warn("[StopLossExecutionJob] Position #{position_id} has no agent, skipping")
      return
    end

    if position.qty.to_f.zero?
      Rails.logger.info("[StopLossExecutionJob] Position #{position_id} qty is zero, skipping")
      return
    end

    service = StopLossExecutionService.new(position, current_price: current_price.to_f)
    service.call
  rescue ActiveRecord::RecordNotFound
    Rails.logger.warn("[StopLossExecutionJob] Position #{position_id} not found")
  end
end
