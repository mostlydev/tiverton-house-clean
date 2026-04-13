require 'ostruct'

class Trades::CancellationService
  attr_reader :trade, :error, :details

  def initialize(trade, options = {})
    @trade = trade
    @cancelled_by = options[:cancelled_by] || 'system'
    @reason = options[:reason]
    @error = nil
    @details = {}
  end

  def call
    # Check if trade can be cancelled
    unless @trade.may_cancel?
      return failure("Cannot cancel trade in #{@trade.status} state", { current_status: @trade.status })
    end

    ActiveRecord::Base.transaction do
      # Cancel Alpaca order if it exists and trade is EXECUTING
      if @trade.EXECUTING? && @trade.alpaca_order_id.present?
        cancel_alpaca_order
      end

      # Transition to CANCELLED
      @trade.cancel!

      # Record cancellation reason if provided
      if @reason.present?
        @trade.update!(denial_reason: @reason)
      end

      # Create audit event
      TradeEvent.create!(
        trade: @trade,
        event_type: 'CANCELLED',
        actor: @cancelled_by,
        details: {
          cancelled_by: @cancelled_by,
          reason: @reason,
          previous_status: @trade.aasm.from_state
        }.compact
      )
    end

    success
  rescue StandardError => e
    Rails.logger.error("Cancellation failed: #{e.message}")
    Rails.logger.error(e.backtrace.join("\n"))

    failure(e.message, { exception: e.class.name })
  end

  private

  def cancel_alpaca_order
    broker = Alpaca::BrokerService.new
    result = broker.cancel_order(order_id: @trade.alpaca_order_id)

    unless result[:success]
      Rails.logger.warn("Failed to cancel Alpaca order #{@trade.alpaca_order_id}: #{result[:error]}")
      raise StandardError, result[:error]
    end
  end

  def success
    OpenStruct.new(success?: true, trade: @trade, error: nil, details: {})
  end

  def failure(error_message, details = {})
    @error = error_message
    @details = details
    OpenStruct.new(success?: false, trade: nil, error: @error, details: @details)
  end
end
