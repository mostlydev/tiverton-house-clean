# frozen_string_literal: true

require "bigdecimal"
require "ostruct"
require "securerandom"

class TradeExecutionService
  class DuplicateExecutionSubmission < StandardError; end

  attr_reader :trade, :error, :details

  def initialize(trade, params = {})
    @trade = trade
    @executed_by = params[:executed_by] || "sentinel"
    @error = nil
    @details = {}
  end

  def call
    # Verify trade can be executed
    unless @trade.can_execute?
      return failure("Trade must be APPROVED and CONFIRMED before execution (current: #{@trade.status})")
    end

    # Step 1: Validate execution guards (SHORT_OK, NOTIONAL_OK, SELL_ALL expansion)
    guard_service = Trades::GuardService.new(@trade)
    guard_service.validate_execution!

    # Step 2: Claim trade (APPROVED → EXECUTING)
    # Guarded by row lock so concurrent execute submissions cannot double-claim.
    claim_trade!

    # Step 3: Execute via Alpaca gem
    broker = Alpaca::BrokerService.new
    execution_result = execute_order(broker)

    if execution_result[:success]
      # Step 4: Record order ID immediately (separate from fill)
      @trade.alpaca_order_id = execution_result[:order_id]
      @trade.save!

      record_broker_order(execution_result)

      # Step 5: Process fill if ready (market orders typically fill immediately)
      if execution_result[:fill_ready]
        fill_processor = Trades::FillProcessorService.new(@trade)
        fill_processor.process_fill(
          qty_filled: execution_result[:qty_filled],
          avg_fill_price: execution_result[:avg_fill_price],
          alpaca_order_id: execution_result[:order_id],
          final: true
        )

      else
        # Order submitted but not filled yet - will be picked up by order reconciliation/activities ingestion
        Rails.logger.info("Order #{execution_result[:order_id]} submitted, awaiting fill")
      end

      success
    else
      # Mark as failed
      @trade.execution_error = execution_result[:error]
      @trade.fail!

      failure(execution_result[:error], alpaca_error: execution_result[:error])
    end

  rescue DuplicateExecutionSubmission => e
    notify_execution_exception(e, guard: "duplicate_execution_submission")
    failure(e.message, guard: "duplicate_execution_submission")

  rescue Trades::GuardService::ValidationError => e
    # Guard check failed - fail trade so it doesn't stay zombie APPROVED
    @trade.execution_error = e.message
    @trade.fail!
    failure("Guard check failed: #{e.message}", guard_error: true)

  rescue StandardError => e
    # Catch any unexpected errors
    @trade.execution_error = e.message
    @trade.fail! if @trade.may_fail?

    failure("Execution failed: #{e.message}", exception: e.class.name, backtrace: e.backtrace.first(5))
  end

  def success?
    @error.nil?
  end

  private

  def claim_trade!
    @trade.with_lock do
      @trade.reload
      unless @trade.can_execute?
        raise DuplicateExecutionSubmission, "Duplicate execution submission blocked for #{@trade.trade_id} (current: #{@trade.status})"
      end

      @trade.executed_by = @executed_by
      @trade.execute!
      Rails.logger.info("Trade #{@trade.trade_id} claimed by #{@executed_by}")
    end
  end

  def execute_order(broker)
    # Determine order parameters
    if should_use_position_close?
      # Use REST position close (if multi-agent isolation passed)
      execute_position_close(broker)
    else
      # Use standard order creation
      execute_standard_order(broker)
    end
  end

  def should_use_position_close?
    return false if %w[crypto crypto_perp us_option].include?(@trade.asset_class)

    # In ledger mode, NEVER use Alpaca's position close API because Alpaca
    # doesn't track our ledger positions. Always use standard orders.
    if LedgerMigration.read_from_ledger?
      Rails.logger.info(
        "Skipping position close API for #{@trade.ticker}: using ledger mode. " \
        "Standard quantity-based SELL will be used."
      )
      return false
    end

    # Legacy mode: use position close API as before
    position = Position.find_by(agent_id: @trade.agent_id, ticker: @trade.ticker)
    return false unless position

    # Check if other agents hold this ticker (shared position scenario)
    # REST position close API requires exclusive ownership — must check BEFORE SELL_ALL
    other_holders = Position.where(ticker: @trade.ticker)
                            .where.not(agent_id: @trade.agent_id)
                            .where.not(qty: 0)
                            .exists?

    if other_holders
      Rails.logger.info(
        "Skipping position close API for #{@trade.ticker}: other agents hold position. " \
        "Using quantity-based SELL instead."
      )
      return false
    end

    # Explicit SELL_ALL keyword (only after confirming no other agents hold the ticker)
    return true if @trade.thesis.to_s.upcase.include?("SELL_ALL")

    # Auto-detect near-complete position closes (SELL orders only)
    return false unless @trade.side.upcase == "SELL"
    return false unless @trade.qty_requested.present?

    # If selling >= 99% of position, treat as full close
    close_percentage = (@trade.qty_requested.to_f / position.qty.to_f) * 100
    if close_percentage >= 99.0
      Rails.logger.info(
        "Auto-routing to position close: selling #{close_percentage.round(2)}% " \
        "of position (#{@trade.qty_requested} / #{position.qty})"
      )
      return true
    end

    false
  end

  def execute_position_close(broker)
    # Close entire position via REST API DELETE.
    # This submits a closing order to Alpaca — it does NOT mean the order is
    # filled. The actual fill will be picked up by OrderReconciliationJob /
    # AccountActivitiesIngestionJob, same as any other order.
    result = broker.close_position(
      ticker: @trade.ticker,
      agent_id: @trade.agent.agent_id
    )

    if result[:success]
      {
        success: true,
        order_id: result[:order_id],
        status: result[:status],
        fill_ready: false
      }
    else
      result
    end
  end

  def execute_standard_order(broker)
    order_params = {
      ticker: @trade.ticker,
      side: @trade.side.downcase,
      order_type: @trade.order_type.downcase,
      extended_hours: @trade.extended_hours,
      asset_class: @trade.asset_class
    }

    # Quantity or notional
    if @trade.qty_requested
      order_qty = effective_execution_qty(broker)
      order_params[:qty] = order_qty

      # Alpaca requires fractional orders to use time_in_force: 'day'
      # Fractional = any quantity that's not a whole number
      if order_qty % 1 != 0
        order_params[:time_in_force] = "day"
        Rails.logger.info("Setting time_in_force=day for fractional qty: #{order_qty}")
      end
    elsif @trade.amount_requested
      order_params[:notional] = @trade.amount_requested
    end

    # Order type specific params
    order_params[:limit_price] = @trade.limit_price if @trade.limit_price
    order_params[:stop_price] = @trade.stop_price if @trade.stop_price
    order_params[:trail_percent] = @trade.trail_percent if @trade.trail_percent
    order_params[:trail_amount] = @trade.trail_amount if @trade.trail_amount

    order_params[:client_order_id] ||= @trade.trade_id

    result = broker.create_order(**order_params)
    result[:order_params] = order_params
    result
  end

  def effective_execution_qty(broker)
    requested_qty = BigDecimal(@trade.qty_requested.to_s)
    
    # Skip snapping logic for BUY orders
    return requested_qty unless @trade.side.to_s.upcase == "SELL"

    broker_qty = broker.get_position_qty(ticker: @trade.ticker)
    
    # If broker position doesn't exist or is zero, validate against ledger before failing
    if broker_qty.nil? || broker_qty <= 0
      if LedgerMigration.read_from_ledger?
        ledger_qty = Position.find_by(agent_id: @trade.agent_id, ticker: @trade.ticker)&.qty || 0
        if ledger_qty > 0
          Rails.logger.warn(
            "Broker position missing for #{@trade.ticker} but ledger shows #{ledger_qty}. " \
            "Using ledger qty for execution (reconciliation drift)."
          )
          broker_qty = ledger_qty.to_f  # Will be converted to BigDecimal below
        else
          raise Alpaca::BrokerService::PositionError, 
                "Cannot sell #{@trade.ticker}: no position found (broker: #{broker_qty.inspect}, ledger: #{ledger_qty})"
        end
      else
        raise Alpaca::BrokerService::PositionError,
              "Cannot sell #{@trade.ticker}: no broker position found (qty: #{broker_qty.inspect})"
      end
    end
    broker_qty = BigDecimal(broker_qty.to_s)

    available_qty = [ broker_qty - locked_sell_qty_excluding_current_trade, BigDecimal("0") ].max
    return requested_qty if available_qty <= 0

    tolerance = sell_all_snap_tolerance(available_qty)
    delta = (requested_qty - available_qty) # Positive when requesting MORE than available

    # Snap down if requesting slightly more than available (dust/rounding protection)
    if delta > 0 && delta <= tolerance
      Rails.logger.info(
        "SELL qty snapped down for #{@trade.trade_id}: " \
        "requested=#{requested_qty.to_s('F')} available=#{available_qty.to_s('F')} " \
        "delta=#{delta.to_s('F')} tolerance=#{tolerance.to_s('F')}"
      )
      return available_qty
    end

    # Snap up for SELL_ALL when close to full position (within tolerance)
    if sell_all_trade? && delta.abs <= tolerance
      Rails.logger.info(
        "SELL_ALL qty snapped for #{@trade.trade_id}: " \
        "requested=#{requested_qty.to_s('F')} available=#{available_qty.to_s('F')} " \
        "delta=#{delta.to_s('F')} tolerance=#{tolerance.to_s('F')}"
      )
      return available_qty
    end

    requested_qty
  rescue StandardError => e
    Rails.logger.warn("Falling back to requested qty for #{@trade.trade_id}: #{e.message}")
    requested_qty
  end

  def sell_all_trade?
    @trade.thesis.to_s.upcase.include?("SELL_ALL")
  end

  def locked_sell_qty_excluding_current_trade
    locked = Trade.where(
      ticker: @trade.ticker,
      side: "SELL",
      asset_class: @trade.asset_class,
      status: [ "APPROVED", "QUEUED", "EXECUTING", "PARTIALLY_FILLED" ]
    ).where.not(id: @trade.id)
     .sum(:qty_requested)

    BigDecimal(locked.to_s)
  end

  def sell_all_snap_tolerance(reference_qty)
    # Small absolute floor handles fractional/crypto dust.
    absolute_floor = @trade.asset_class == "crypto" ? BigDecimal("0.00000001") : BigDecimal("0.000001")
    # Relative tolerance keeps behavior proportional for larger sizes.
    relative = reference_qty.abs * BigDecimal("0.00001") # 1 bps
    # Cap prevents overly permissive snapping on large positions.
    capped = [ relative, BigDecimal("0.0001") ].min
    [ capped, absolute_floor ].max
  end

  def record_broker_order(execution_result)
    order_id = execution_result[:order_id]
    return if order_id.blank?
    return if BrokerOrder.exists?(broker_order_id: order_id)

    params = execution_result[:order_params] || {}
    BrokerOrder.create!(
      broker_order_id: order_id,
      client_order_id: params[:client_order_id] || @trade.trade_id || SecureRandom.uuid,
      trade: @trade,
      agent: @trade.agent,
      ticker: @trade.ticker,
      side: @trade.side.to_s.downcase,
      order_type: @trade.order_type.to_s.downcase.presence || "market",
      time_in_force: params[:time_in_force],
      requested_tif: params[:time_in_force],
      effective_tif: params[:time_in_force],
      extended_hours: @trade.extended_hours,
      qty_requested: @trade.qty_requested,
      notional_requested: @trade.amount_requested,
      limit_price: @trade.limit_price,
      stop_price: @trade.stop_price,
      trail_percent: @trade.trail_percent,
      trail_price: @trade.trail_amount,
      status: execution_result[:status],
      submitted_at: Time.current,
      raw_request: params,
      raw_response: execution_result.except(:order_params),
      asset_class: @trade.asset_class
    )
  rescue ActiveRecord::RecordNotUnique
    nil
  rescue StandardError => e
    Rails.logger.error("BrokerOrder create failed for #{@trade.trade_id}: #{e.class} #{e.message}")
  end

  def success
    OpenStruct.new(success?: true, trade: @trade, error: nil, details: {})
  end

  def failure(error_message, details = {})
    @error = error_message
    @details = details
    OpenStruct.new(success?: false, trade: @trade, error: @error, details: @details)
  end

  def notify_execution_exception(exception, guard:)
    Trades::RemediationAlertService.exception!(
      scope: "trade_execution",
      exception: exception,
      context: {
        guard: guard,
        trade_id: @trade&.trade_id,
        status: @trade&.status,
        agent_id: @trade&.agent&.agent_id,
        ticker: @trade&.ticker,
        side: @trade&.side
      }
    )
  rescue StandardError => e
    Rails.logger.error("Execution remediation notify failed: #{e.class}: #{e.message}")
  end
end
