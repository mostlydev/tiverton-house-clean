require "ostruct"
require "bigdecimal"
require "securerandom"
require "digest"

class TradeProposalService
  DUPLICATE_GUARD_STATUSES = %w[PROPOSED APPROVED QUEUED EXECUTING PARTIALLY_FILLED].freeze
  NO_COOLDOWN_GUARDS = %w[market_order_params missing_sizing].freeze

  attr_reader :trade, :error, :details, :trade_request

  def initialize(params)
    @params = params
    @agent = params[:agent]
    @ticker = TickerNormalizer.normalize(params[:ticker])
    @side = params[:side]&.upcase
    @qty_requested = params[:qty_requested]
    @amount_requested = params[:amount_requested]
    @order_type = params[:order_type] || "MARKET"
    @extended_hours = if params.key?(:extended_hours)
                        ActiveModel::Type::Boolean.new.cast(params[:extended_hours])
    else
                        false
    end
    @asset_class = resolve_asset_class(params[:asset_class])
    @execution_policy = resolve_execution_policy(params[:execution_policy], @asset_class)
    @asset_class_provided = params.key?(:asset_class)
    @execution_policy_provided = params.key?(:execution_policy)
    @thesis = params[:thesis]
    normalize_advisory_trailing_fields!
    @is_urgent = params[:is_urgent] || false
    @source = params[:source] || "api"
    @source_message_id = params[:source_message_id]
    @trade = nil
    @error = nil
    @details = {}
    @trade_request = nil

    # Request ID handling: Phase A compatibility
    # If request_id provided, use it (client mode)
    # If not provided, generate one (server_generated mode)
    @client_request_id = params[:request_id]
    @request_id = @client_request_id || generate_request_id
    @idempotency_mode = @client_request_id.present? ? "client" : "server_generated"
  end

  def call
    # IDEMPOTENCY CHECK: Return existing result if request_id already processed
    existing_request = TradeRequest.find_by(request_id: @request_id)
    if existing_request
      return handle_existing_request(existing_request)
    end
    return failure("Agent is required", agent: "missing") unless @agent
    return failure("Ticker is required", ticker: "missing") unless @ticker
    return failure("Side is required", side: "missing") unless @side
    return failure("Side must be BUY or SELL", side: @side) unless %w[BUY SELL].include?(@side)

    # GUARD: Per-agent-per-ticker failure cooldown to prevent rapid-fire broken submissions
    cooldown_result = check_failure_cooldown
    return cooldown_result if cooldown_result

    # Validate order type requirements
    validate_result = validate_order_type
    return validate_result unless validate_result.nil?

    # Must have qty or amount
    if @qty_requested.blank? && @amount_requested.blank?
      return failure(
        missing_sizing_error,
        guard: "missing_sizing",
        immediate_retry_allowed: true,
        remediation: missing_sizing_remediation
      )
    end

    # GUARD: Disallow notional sells unless explicitly allowed in thesis
    if @side == "SELL" && @amount_requested.present? && @qty_requested.blank?
      unless crypto_like?(@asset_class) || @thesis&.upcase&.include?("NOTIONAL_OK")
        return failure(
          "SELL requires qty_requested (not amount_requested). If intentional notional sell, include NOTIONAL_OK in thesis.",
          guard: "notional_sell"
        )
      end
    end

    # GUARD: Notional orders must be MARKET for equities/options
    if @amount_requested.present? && @order_type != "MARKET" && !crypto_like?(@asset_class)
      return failure(
        "Notional orders must be MARKET. Use qty_requested for #{@order_type} orders.",
        guard: "notional_order_type"
      )
    end

    # GUARD: Check for in-flight trades (EXECUTING/PARTIALLY_FILLED)
    in_flight = Trade.where(agent: @agent, ticker: @ticker, status: [ "EXECUTING", "PARTIALLY_FILLED" ]).first
    if in_flight
      return failure(
        "Cannot propose #{@side} #{@ticker} - trade #{in_flight.trade_id} is currently #{in_flight.status}",
        guard: "in_flight",
        in_flight_trade_id: in_flight.trade_id,
        in_flight_status: in_flight.status
      )
    end

    # GUARD: Prevent duplicate BUY proposals already APPROVED/EXECUTING
    if @side == "BUY"
      # GUARD: One-agent-per-ticker policy (enforced at proposal time)
      other_agent_position = find_other_agent_position
      if other_agent_position
        return failure(
          "Cannot propose BUY #{@ticker} - already held by #{other_agent_position.agent.agent_id}. One-agent-per-ticker policy enforced at proposal time.",
          guard: "single_agent_ticker",
          holder_agent_id: other_agent_position.agent.agent_id
        )
      end

      pending_buy = Trade.where(agent: @agent, ticker: @ticker, side: "BUY", status: [ "APPROVED", "QUEUED", "EXECUTING" ]).first
      if pending_buy
        return failure(
          "Cannot propose BUY #{@ticker} - trade #{pending_buy.trade_id} already pending",
          guard: "duplicate_buy",
          pending_trade_id: pending_buy.trade_id
        )
      end
    end

    # GUARD: Prevent unsupported notional orders for options
    if @asset_class == "us_option" && @amount_requested.present?
      return failure("Options orders must specify qty_requested (contracts). Notional orders are not supported.")
    end

    # GUARD: Prevent SELL that would exceed available shares
    if @side == "SELL" && @qty_requested.present?
      position_qty = current_position_qty

      # Calculate locked quantity from pending sells
      locked_qty = Trade.where(
        agent: @agent,
        ticker: @ticker,
        side: "SELL",
        status: [ "APPROVED", "QUEUED", "EXECUTING", "PARTIALLY_FILLED" ]
      ).sum(:qty_requested) || 0

      available_qty = position_qty - locked_qty

      # Crypto: no short selling at all
      if spot_crypto?(@asset_class) && position_qty <= 0
        return failure(
          "Cannot short sell crypto. No position exists for #{@ticker}.",
          guard: "short_sell_crypto",
          position_qty: position_qty
        )
      end

      # Equities: allow shorting only with SHORT_OK
      if position_qty.zero?
        unless @thesis&.upcase&.include?("SHORT_OK")
          return failure(
            "Cannot SELL #{@ticker} - no position exists. If intentional short, include SHORT_OK in thesis.",
            guard: "short_sell",
            position_qty: 0
          )
        end
      elsif @qty_requested > available_qty
        return failure(
          "Cannot sell #{@qty_requested} #{@ticker} - only #{available_qty} available (#{locked_qty} locked)",
          guard: "insufficient_qty",
          position_qty: position_qty,
          locked_qty: locked_qty,
          available_qty: available_qty,
          requested_qty: @qty_requested
        )
      end
    end

    # GUARD: Prevent accidental duplicate submissions from context drift/retries
    duplicate_trade = recent_duplicate_submission
    if duplicate_trade
      notify_duplicate_submission(duplicate_trade, "duplicate_submission")
      return failure(
        "Duplicate submission blocked - existing trade #{duplicate_trade.trade_id} is #{duplicate_trade.status}",
        guard: "duplicate_submission",
        existing_trade_id: duplicate_trade.trade_id,
        existing_trade_status: duplicate_trade.status
      )
    end

    # GUARD: Research file must exist and not be a bare template for non-momentum BUYs
    if research_guard_required?
      research_result = validate_research_file
      return research_result if research_result
    end

    # Check for existing PROPOSED for same agent+ticker - update instead of create
    existing = Trade.find_by(agent: @agent, ticker: @ticker, status: "PROPOSED")
    if existing
      @trade = existing  # Set @trade first so update_params can read existing values
      existing.update!(update_params)
      record_trade_request("accepted")
      return success
    end

    # Create new trade
    @trade = Trade.create!(create_params)
    record_trade_request("accepted")

    success
  rescue StandardError => e
    notify_exception(e, scope: "trade_proposal")
    record_trade_request("rejected", e.message)
    failure("Proposal failed: #{e.message}", exception: e.class.name)
  end

  def success?
    @error.nil?
  end

  def request_id
    @request_id
  end

  def idempotency_mode
    @idempotency_mode
  end

  private

  def generate_request_id
    # Generate a deterministic request ID based on payload for server-generated mode
    # This allows natural deduplication even without client-provided IDs
    timestamp = Time.current.strftime("%Y%m%d%H%M%S")
    payload_hash = normalized_payload_hash[0..7]
    "srv-#{timestamp}-#{payload_hash}"
  end

  def normalized_payload_hash
    # Create deterministic hash of the request payload for duplicate detection
    payload = {
      agent_id: @agent&.agent_id,
      ticker: @ticker,
      side: @side,
      qty_requested: @qty_requested.to_s,
      amount_requested: @amount_requested.to_s,
      order_type: @order_type,
      extended_hours: @extended_hours,
      asset_class: @asset_class,
      execution_policy: @execution_policy
    }
    Digest::SHA256.hexdigest(payload.to_json)
  end

  def handle_existing_request(existing_request)
    @trade_request = existing_request
    @trade = existing_request.trade

    case existing_request.status
    when "accepted"
      # Return the original successful result idempotently
      OpenStruct.new(
        success?: true,
        trade: @trade,
        error: nil,
        details: {
          idempotent: true,
          request_id: @request_id,
          idempotency_mode: @idempotency_mode,
          original_request_at: existing_request.created_at
        }
      )
    when "duplicate"
      failure(
        "Request #{@request_id} was previously marked as duplicate",
        idempotent: true,
        request_id: @request_id,
        original_request_at: existing_request.created_at
      )
    when "rejected"
      failure(
        existing_request.rejection_reason || "Request #{@request_id} was previously rejected",
        idempotent: true,
        request_id: @request_id,
        original_request_at: existing_request.created_at
      )
    end
  end

  def record_trade_request(status, rejection_reason = nil)
    @trade_request = TradeRequest.create!(
      request_id: @request_id,
      source: @source,
      source_message_id: @source_message_id,
      normalized_payload_hash: normalized_payload_hash,
      agent: @agent,
      ticker: @ticker,
      intent_side: map_intent_side,
      order_type: @order_type,
      qty_requested: @qty_requested,
      notional_requested: @amount_requested,
      status: status,
      trade: @trade,
      rejection_reason: rejection_reason
    )
  rescue StandardError => e
    # Don't fail the trade proposal if request tracking fails
    Rails.logger.error("Failed to record trade_request: #{e.message}")
  end

  def map_intent_side
    # Map simple BUY/SELL to intent side based on position
    return nil unless @side

    if @side == "BUY"
      "BUY_TO_OPEN"  # Default for buys
    elsif @side == "SELL"
      # Check if this is closing a position or opening a short
      position = Position.find_by(agent: @agent, ticker: @ticker)
      if position && position.qty.to_f > 0
        "SELL_TO_CLOSE"
      elsif @thesis&.upcase&.include?("SHORT_OK")
        "SELL_TO_OPEN"
      else
        "SELL_TO_CLOSE"
      end
    end
  end

  def validate_order_type
    return validate_crypto_order_type if crypto_like?(@asset_class)
    return validate_option_order_type if @asset_class == "us_option"

    case @order_type
    when "MARKET"
      # MARKET orders execute at any price — price-constraint params are invalid
      invalid = []
      invalid << "stop_price" if @params[:stop_price].present?
      unless invalid.empty?
        return failure(
          market_order_param_error(invalid),
          guard: "market_order_params",
          invalid_fields: invalid,
          immediate_retry_allowed: true,
          remediation: market_order_param_remediation(invalid)
        )
      end
    when "LIMIT"
      return failure("LIMIT order requires limit_price") if @params[:limit_price].blank?
    when "STOP"
      return failure("STOP order requires stop_price") if @params[:stop_price].blank?
    when "STOP_LIMIT"
      if @params[:limit_price].blank? || @params[:stop_price].blank?
        return failure("STOP_LIMIT order requires both limit_price and stop_price")
      end
    when "TRAILING_STOP"
      if @params[:trail_percent].blank? && @params[:trail_amount].blank?
        return failure("TRAILING_STOP requires trail_percent or trail_amount")
      end
    else
      return failure("Unknown order type: #{@order_type}", order_type: @order_type)
    end

    nil # All validations passed
  end

  def validate_crypto_order_type
    case @order_type
    when "MARKET", "LIMIT"
      return failure("LIMIT order requires limit_price") if @order_type == "LIMIT" && @params[:limit_price].blank?
    when "STOP_LIMIT"
      if @params[:limit_price].blank? || @params[:stop_price].blank?
        return failure("STOP_LIMIT order requires both limit_price and stop_price")
      end
    when "TRAILING_STOP"
      return failure("TRAILING_STOP is not supported for crypto orders")
    else
      return failure("Unknown order type: #{@order_type}", order_type: @order_type)
    end

    nil
  end

  def validate_option_order_type
    return failure("Options do not support extended_hours") if @extended_hours == true

    case @order_type
    when "MARKET"
      nil
    when "LIMIT"
      return failure("LIMIT order requires limit_price") if @params[:limit_price].blank?
    when "STOP"
      return failure("STOP order requires stop_price") if @params[:stop_price].blank?
    when "STOP_LIMIT"
      if @params[:limit_price].blank? || @params[:stop_price].blank?
        return failure("STOP_LIMIT order requires both limit_price and stop_price")
      end
    when "TRAILING_STOP"
      return failure("TRAILING_STOP is not supported for options orders")
    else
      return failure("Unknown order type: #{@order_type}", order_type: @order_type)
    end

    nil
  end

  def create_params
    {
      agent: @agent,
      ticker: @ticker,
      side: @side,
      qty_requested: @qty_requested,
      amount_requested: @amount_requested,
      order_type: @order_type,
      extended_hours: @extended_hours,
      asset_class: @asset_class,
      execution_policy: @execution_policy,
      limit_price: @params[:limit_price],
      stop_price: @params[:stop_price],
      trail_percent: @params[:trail_percent],
      trail_amount: @params[:trail_amount],
      stop_loss: @params[:stop_loss],
      target_price: @params[:target_price],
      thesis: @thesis,
      is_urgent: @is_urgent,
      status: "PROPOSED"
    }
  end

  def update_params
    {
      side: @side,
      qty_requested: @qty_requested,
      amount_requested: @amount_requested,
      order_type: @order_type,
      extended_hours: @extended_hours,
      asset_class: @asset_class_provided ? @asset_class : @trade&.asset_class,
      execution_policy: @execution_policy_provided ? @execution_policy : @trade&.execution_policy,
      limit_price: @params[:limit_price],
      stop_price: @params[:stop_price],
      trail_percent: @params[:trail_percent],
      trail_amount: @params[:trail_amount],
      stop_loss: @params[:stop_loss],
      target_price: @params[:target_price],
      thesis: @thesis || @trade&.thesis, # Preserve existing thesis if not provided
      is_urgent: @is_urgent
    }
  end

  def resolve_asset_class(raw)
    normalized = raw.to_s.strip.downcase
    return "us_option" if %w[option options us_option].include?(normalized)
    return normalized if normalized.present?
    return "crypto" if @ticker.to_s.include?("/")
    return "us_option" if option_symbol?(@ticker)

    "us_equity"
  end

  def resolve_execution_policy(raw, asset_class)
    normalized = raw.to_s.strip.downcase
    return normalized if normalized.present?
    return @agent.default_execution_policy if @agent&.default_execution_policy.present?

    crypto_like?(asset_class) ? "immediate" : "allow_extended"
  end

  def crypto_like?(asset_class)
    %w[crypto crypto_perp].include?(asset_class)
  end

  def spot_crypto?(asset_class)
    asset_class == "crypto"
  end

  def option_symbol?(ticker)
    ticker.to_s.match?(/\A[A-Z]{1,6}\d{6}[CP]\d{8}\z/)
  end

  def success
    OpenStruct.new(
      success?: true,
      trade: @trade,
      error: nil,
      details: {
        request_id: @request_id,
        idempotency_mode: @idempotency_mode
      }
    )
  end

  def failure_cooldown_seconds
    AppConfig.proposal_failure_cooldown_seconds
  end

  def failure_cooldown_cache_key
    "proposal_failure_cooldown:#{@agent&.agent_id}:#{@ticker}"
  end

  def check_failure_cooldown
    return nil if failure_cooldown_seconds <= 0
    return nil unless @agent && @ticker

    cached = Rails.cache.read(failure_cooldown_cache_key)
    return nil unless cached

    elapsed = Time.current - Time.parse(cached[:failed_at])
    remaining = (failure_cooldown_seconds - elapsed).ceil

    return nil if remaining <= 0

    failure(
      "Proposal cooldown active for #{@ticker} — wait #{remaining}s before resubmitting. Previous failure: #{cached[:reason].to_s.truncate(80)}",
      guard: "failure_cooldown",
      cooldown_remaining: remaining,
      previous_failure: cached[:reason]
    )
  rescue StandardError => e
    Rails.logger.warn("Failure cooldown check error: #{e.message}")
    nil
  end

  def set_failure_cooldown
    return if failure_cooldown_seconds <= 0
    return unless @agent && @ticker
    return if @details[:guard] == "failure_cooldown" # Don't extend cooldown from cooldown rejections
    return if NO_COOLDOWN_GUARDS.include?(@details[:guard].to_s)

    Rails.cache.write(
      failure_cooldown_cache_key,
      { failed_at: Time.current.iso8601, reason: @error },
      expires_in: failure_cooldown_seconds.seconds
    )
  rescue StandardError => e
    Rails.logger.warn("Failure cooldown set error: #{e.message}")
  end

  def duplicate_window_seconds
    AppConfig.trades_duplicate_window_seconds
  end

  def normalize_advisory_trailing_fields!
    fragments = extract_advisory_trail_fragments!(
      percent_key: :manual_trail_percent,
      amount_key: :manual_trail_amount
    )

    if @order_type != "TRAILING_STOP"
      fragments.concat(
        extract_advisory_trail_fragments!(
          percent_key: :trail_percent,
          amount_key: :trail_amount
        )
      )
    end

    return if fragments.empty?

    @thesis = [@thesis.presence, "Advisory trailing plan: #{fragments.uniq.join('; ')}."].compact.join("\n")
    @params[:thesis] = @thesis
  end

  def extract_advisory_trail_fragments!(percent_key:, amount_key:)
    fragments = []

    trail_percent = @params.delete(percent_key).to_s.strip
    fragments << "manual trail #{trail_percent}%" if trail_percent.present?

    trail_amount = @params.delete(amount_key).to_s.strip
    fragments << "manual trail $#{trail_amount}" if trail_amount.present?

    fragments
  end

  def market_order_param_error(invalid_fields)
    guidance = []
    guidance << "Use manual_trail_percent/manual_trail_amount (or thesis) for advisory trailing plans." if invalid_fields.intersect?(%w[trail_percent trail_amount])
    guidance << "Use TRAILING_STOP only for executable trailing stops." if invalid_fields.intersect?(%w[trail_percent trail_amount])
    guidance << "Use STOP for executable stop orders." if invalid_fields.include?("stop_price")

    "MARKET orders cannot have #{invalid_fields.join(', ')}. #{guidance.join(' ')}".strip
  end

  def missing_sizing_error
    "Must specify qty_requested or amount_requested. Use qty_requested for share sizing or amount_requested for dollar sizing. For a tiny share flow test, use qty_requested: 1."
  end

  def missing_sizing_remediation
    {
      required_one_of: %w[qty_requested amount_requested],
      retry_immediately: true,
      examples: [
        { "qty_requested" => 1 },
        { "amount_requested" => 100 }
      ]
    }
  end

  def recent_duplicate_submission
    return nil if duplicate_window_seconds <= 0

    window_start = duplicate_window_seconds.seconds.ago
    candidates = Trade.where(agent: @agent, ticker: @ticker, side: @side, status: DUPLICATE_GUARD_STATUSES)
                      .where("created_at >= ?", window_start)
                      .order(created_at: :desc)

    candidates.find { |candidate| same_submission_payload?(candidate) }
  end

  def same_submission_payload?(candidate)
    decimal_equal?(candidate.qty_requested, @qty_requested) &&
      decimal_equal?(candidate.amount_requested, @amount_requested) &&
      candidate.order_type.to_s.upcase == @order_type.to_s.upcase &&
      candidate.asset_class.to_s == @asset_class.to_s &&
      candidate.execution_policy.to_s == @execution_policy.to_s &&
      candidate.extended_hours == @extended_hours &&
      decimal_equal?(candidate.limit_price, @params[:limit_price]) &&
      decimal_equal?(candidate.stop_price, @params[:stop_price]) &&
      decimal_equal?(candidate.trail_percent, @params[:trail_percent]) &&
      decimal_equal?(candidate.trail_amount, @params[:trail_amount])
  end

  def decimal_equal?(left, right)
    left_value = decimal_or_nil(left)
    right_value = decimal_or_nil(right)
    return true if left_value.nil? && right_value.nil?
    return false if left_value.nil? || right_value.nil?

    left_value == right_value
  end

  def decimal_or_nil(value)
    return nil if value.nil? || value.to_s.strip.empty?

    BigDecimal(value.to_s).round(8)
  rescue ArgumentError
    nil
  end

  def notify_duplicate_submission(existing_trade, guard)
    Trades::RemediationAlertService.duplicate_submission!(
      incoming: {
        agent_id: @agent.agent_id,
        ticker: @ticker,
        side: @side,
        qty_requested: @qty_requested,
        amount_requested: @amount_requested,
        order_type: @order_type
      },
      existing: {
        trade_id: existing_trade.trade_id,
        status: existing_trade.status
      },
      guard: guard
    )
  rescue StandardError => e
    Rails.logger.error("Duplicate remediation notify failed: #{e.class}: #{e.message}")
  end

  def notify_exception(exception, scope:)
    Trades::RemediationAlertService.exception!(
      scope: scope,
      exception: exception,
      context: {
        agent_id: @agent&.agent_id,
        ticker: @ticker,
        side: @side,
        qty_requested: @qty_requested,
        amount_requested: @amount_requested,
        order_type: @order_type
      }
    )
  rescue StandardError => e
    Rails.logger.error("Exception remediation notify failed: #{e.class}: #{e.message}")
  end

  def current_position_qty
    if LedgerMigration.read_from_ledger?
      projection = Ledger::ProjectionService.new
      position = projection.position_for(@agent, @ticker)
      position ? position[:qty].to_f : 0
    else
      Position.find_by(agent: @agent, ticker: @ticker)&.qty.to_f || 0
    end
  end

  def find_other_agent_position
    if LedgerMigration.read_from_ledger?
      lot = PositionLot.where(ticker: @ticker.to_s.upcase, closed_at: nil)
                      .where.not(agent_id: @agent.id)
                      .group(:agent_id)
                      .having("SUM(qty) != 0")
                      .select("agent_id, SUM(qty) as qty")
                      .unscope(:order)
                      .take
      return nil unless lot

      OpenStruct.new(agent: Agent.find(lot.agent_id), qty: lot.qty.to_f)
    else
      Position.where(ticker: @ticker)
              .joins(:agent)
              .where("positions.qty != 0")
              .where.not(agents: { id: @agent.id })
              .first
    end
  end

  def validate_research_file
    # Skip for crypto pairs - file paths don't work with /
    return nil if @ticker.to_s.include?("/")

    research_path = StoragePaths.research_file_path(@ticker)

    unless research_path.exist?
      return failure(
        "Research file missing for #{@ticker}. Create #{research_path} before proposing. Include RESEARCH_OK in thesis to bypass.",
        guard: "missing_research"
      )
    end

    content = research_path.read.strip
    if content.empty? || research_file_is_template?(content)
      return failure(
        "Research file for #{@ticker} is still the unfilled template. Populate it before proposing. Include RESEARCH_OK in thesis to bypass.",
        guard: "template_research"
      )
    end

    nil
  rescue StandardError => e
    # Don't block trades if research file check fails for unexpected reasons
    Rails.logger.warn("Research file check failed for #{@ticker}: #{e.message}")
    nil
  end

  def research_guard_required?
    return false unless @side == "BUY"
    return false if @thesis&.upcase&.include?("RESEARCH_OK")
    return false if momentum_agent?

    true
  end

  def momentum_agent?
    @agent&.style.to_s.casecmp("momentum").zero?
  end

  def research_file_is_template?(content)
    first_line = content.lines.first.to_s.strip
    # Only catch completely untouched templates where the title was never changed
    first_line == "# TICKER - Company Name" ||
      first_line == "# [TICKER] Research" ||
      first_line.start_with?("# TICKER ")
  end

  def failure(error_message, details = {})
    @error = error_message
    @details = details.merge(
      request_id: @request_id,
      idempotency_mode: @idempotency_mode
    )
    set_failure_cooldown
    OpenStruct.new(success?: false, trade: nil, error: @error, details: @details)
  end

  def market_order_param_remediation(invalid_fields)
    remediation = {
      remove_fields: invalid_fields,
      retry_immediately: true
    }

    executable_alternatives = {}
    if invalid_fields.intersect?(%w[trail_percent trail_amount])
      remediation[:use_fields_instead] = {
        "trail_percent" => "manual_trail_percent",
        "trail_amount" => "manual_trail_amount"
      }.slice(*invalid_fields)
      executable_alternatives["trail_percent"] = "TRAILING_STOP" if invalid_fields.include?("trail_percent")
      executable_alternatives["trail_amount"] = "TRAILING_STOP" if invalid_fields.include?("trail_amount")
    end

    executable_alternatives["stop_price"] = "STOP" if invalid_fields.include?("stop_price")
    remediation[:executable_alternatives] = executable_alternatives if executable_alternatives.any?
    remediation
  end
end
