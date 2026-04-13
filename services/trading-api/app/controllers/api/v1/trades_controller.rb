module Api
  module V1
    class TradesController < ApplicationController
      trail_responses
      trail_tool :index, scope: :agent, name: "list_trades",
        description: "List trades with optional filters by agent, status, or ticker.",
        query: {
          agent_id: { type: "string", description: "Filter to a specific trader" },
          status: { type: "string", description: "Comma-separated statuses (for example PROPOSED,PENDING)" },
          ticker: { type: "string", description: "Filter by ticker" },
          limit: { type: "integer", description: "Max results (default 100)" }
        }
      trail_tool :show, scope: :agent, name: "get_trade",
        description: "Get details of a specific trade by trade_id.",
        path: "/api/v1/trades/{trade_id}",
        required: [:trade_id]
      trail_tool :create, scope: :agent, name: "propose_trade",
        description: <<~DESC.squish,
          Propose a new trade for review. Agent identity is derived from your auth token.
          Most BUY orders require a populated research file at storage/shared/research/tickers/<TICKER>.md
          (the shared desk copy, not your private notes/<ticker>.md). The first line must be changed
          from the template default. Momentum traders may submit fast BUY proposals without that file,
          but should backfill the shared research record later. Any trader can include RESEARCH_OK in
          thesis to bypass.
          You must provide one of qty_requested or amount_requested. For a tiny flow test, use qty_requested: 1.
          Some proposal failures apply a short cooldown before you can resubmit the same ticker.
          Order type determines which price params are valid — see parameter descriptions.
          Advisory fields (stop_loss, target_price) are always allowed regardless of order type.
          Manual trailing plans belong in thesis text or manual_trail_percent/manual_trail_amount,
          not trail_percent or trail_amount.
        DESC
        exclude_params: [:agent_id, :request_id, :source, :source_message_id],
        required: [:ticker, :side],
        query: {
          qty_requested: {
            type: "number",
            minimum: 0.0001,
            examples: [ 1 ],
            description: "Share, contract, or unit quantity. Required unless amount_requested is present. For a tiny share flow test, use qty_requested: 1."
          },
          amount_requested: {
            type: "number",
            minimum: 0.01,
            examples: [ 100 ],
            description: "Dollar notional sizing. Required unless qty_requested is present. Useful for BUY MARKET sizing by dollars; equities/options SELL proposals should usually use qty_requested."
          },
          order_type: {
            type: "string",
            enum: %w[MARKET LIMIT STOP STOP_LIMIT TRAILING_STOP],
            default: "MARKET",
            description: "Execution order type. Default MARKET. Use TRAILING_STOP only for executable trailing stops. For advisory/manual trailing plans, use manual_trail_percent, manual_trail_amount, or thesis instead. LIMIT requires limit_price. STOP requires stop_price. STOP_LIMIT requires both. TRAILING_STOP requires trail_percent or trail_amount."
          },
          trail_percent: {
            type: "number",
            minimum: 0.0001,
            description: "Executable trailing stop percentage. Only valid with order_type=TRAILING_STOP. Do not use for manual trailing plans."
          },
          trail_amount: {
            type: "number",
            minimum: 0.0001,
            description: "Executable trailing stop dollar amount. Only valid with order_type=TRAILING_STOP. Do not use for manual trailing plans."
          },
          manual_trail_percent: {
            type: "number",
            minimum: 0.0001,
            description: "Advisory/manual trailing percentage only. Safe on MARKET, LIMIT, or STOP proposals. This is added to thesis text and does not place an executable trailing stop."
          },
          manual_trail_amount: {
            type: "number",
            minimum: 0.0001,
            description: "Advisory/manual trailing dollar amount only. Safe on MARKET, LIMIT, or STOP proposals. This is added to thesis text and does not place an executable trailing stop."
          },
          stop_price: {
            type: "number",
            minimum: 0.0001,
            description: "Stop trigger price for order execution. Only valid with order_type=STOP or STOP_LIMIT. This is NOT the same as stop_loss (advisory risk field)."
          },
          limit_price: {
            type: "number",
            minimum: 0.0001,
            description: "Limit price for order execution. Required for LIMIT and STOP_LIMIT orders. Also accepted on MARKET orders (auto-converts to LIMIT)."
          },
          stop_loss: {
            type: "number",
            minimum: 0.0001,
            description: "Advisory stop-loss price for risk management. Allowed on any order type. This is NOT an order execution param — use stop_price with order_type=STOP for executable stop orders."
          },
          target_price: {
            type: "number",
            minimum: 0.0001,
            description: "Advisory profit target price. Allowed on any order type. Informational only — does not affect order execution."
          },
          thesis: {
            type: "string",
            description: "Trade rationale. Non-momentum BUYs normally need shared research unless you include RESEARCH_OK. Include SHORT_OK for intentional short sells. Include NOTIONAL_OK for notional SELL orders. Put manual trailing plans here if you are not using manual_trail_percent or manual_trail_amount."
          }
        }
      trail_tool :pending, scope: :agent, name: "get_pending_trades",
        description: "List all PROPOSED and PENDING trades awaiting review."
      trail_tool :approve, scope: :coordinator, name: "approve_trade",
        description: "Approve a trade after compliance review."
      trail_tool :deny, scope: :coordinator, name: "deny_trade",
        description: "Deny a trade with reason.",
        query: {
          reason: { type: "string", description: "Denial reason" }
        }
      trail_tool :pass, scope: :agent, name: "pass_trade",
        description: "Pass on a proposed trade and decline to confirm it."
      trail_tool :confirm, scope: :agent, name: "confirm_trade",
        description: "Confirm your intent on a proposed trade."
      trail_tool :cancel, scope: :agent, name: "cancel_trade",
        description: "Cancel a trade. Traders can cancel their own trades and coordinators can cancel any trade.",
        query: {
          reason: { type: "string", description: "Cancellation reason" }
        }

      before_action :set_trade, only: [ :show, :approve, :deny, :pass, :confirm, :cancel, :execute, :fill, :fail ]
      before_action :require_api_principal!, only: [ :create, :approve, :deny, :pass, :confirm, :cancel, :execute, :fill, :fail ]
      before_action :require_coordinator_or_internal_api_principal!, only: [ :approve, :deny ]
      before_action :require_trade_owner_or_internal_for_pass_or_confirm!, only: [ :pass, :confirm ]
      before_action :require_trade_cancel_authorization!, only: [ :cancel ]
      before_action :require_internal_api_principal!, only: [ :execute, :fill, :fail ]

      # GET /api/v1/trades
      def index
        @trades = Trade.includes(:agent)
                      .order(created_at: :desc)
                      .limit(params[:limit] || 100)

        # Optional filters
        @trades = @trades.where(agent_id: params[:agent_id]) if params[:agent_id]
        if params[:status]
          statuses = params[:status].to_s.split(",").map(&:strip).reject(&:blank?)
          @trades = @trades.where(status: statuses) if statuses.any?
        end
        @trades = @trades.where(ticker: params[:ticker]) if params[:ticker]

        render json: @trades.map { |t| trade_json(t) }, trail: false
      end

      # GET /api/v1/trades/:id
      def show
        render json: trade_json(@trade), trail: @trade
      end

      # GET /api/v1/trades/pending
      # Tiverton's view: PROPOSED or PENDING trades
      def pending
        @trades = Trade.where(status: [ "PROPOSED", "PENDING" ])
                      .includes(:agent)
                      .order(created_at: :asc)

        render json: @trades.map { |t| trade_json(t) }, trail: false
      end

      # GET /api/v1/trades/approved
      # Sentinel's view: APPROVED trades ready for execution
      def approved
        @trades = Trade.approved
                      .includes(:agent)
                      .order(confirmed_at: :asc, created_at: :asc)

        render json: @trades.map { |t| trade_json(t) }, trail: false
      end

      # GET /api/v1/trades/stale_proposals
      # Find proposals older than threshold (default 15 minutes)
      def stale_proposals
        threshold = (params[:minutes] || AppConfig.trades_stale_proposal_minutes).to_i.minutes.ago
        @trades = Trade.where(status: "PROPOSED")
                      .where("created_at < ?", threshold)
                      .includes(:agent)
                      .order(created_at: :asc)

        render json: @trades.map { |t| trade_json(t).merge(age_minutes: ((Time.current - t.created_at) / 60).to_i) }, trail: false
      end

      # GET /api/v1/trades/stale_approved
      # Find approved trades older than threshold (default 5 minutes)
      # Used for reconfirmation requests
      def stale_approved
        threshold = (params[:minutes] || AppConfig.trades_stale_approval_minutes).to_i.minutes.ago
        @trades = Trade.where(status: "APPROVED")
                      .where("approved_at < ?", threshold)
                      .includes(:agent)
                      .order(approved_at: :asc)

        render json: @trades.map { |t| trade_json(t).merge(age_minutes: ((Time.current - t.approved_at) / 60).to_i) }, trail: false
      end

      # POST /api/v1/trades
      def create
        proposal_params = trade_params
        return if proposal_params.nil?

        result = TradeProposalService.new(proposal_params).call

        if result.success?
          response = trade_json(result.trade).merge(
            request_id: result.details[:request_id],
            idempotency_mode: result.details[:idempotency_mode]
          )
          response[:idempotent] = true if result.details[:idempotent]
          render json: response, trail: result.trade, status: :created
        else
          notify_trade_proposal_failure(proposal_params, result.error, result.details)
          render json: { error: result.error, details: result.details }, status: :unprocessable_entity
        end
      end

      # POST /api/v1/trades/:id/approve
      def approve
        if @trade.may_approve?
          @trade.approved_by = approval_actor
          @trade.approve!
          render json: trade_json(@trade), trail: @trade
        else
          render json: { error: "Cannot approve trade in #{@trade.status} state" }, status: :unprocessable_entity
        end
      end

      # POST /api/v1/trades/:id/deny
      def deny
        if @trade.may_deny?
          @trade.denial_reason = params[:reason]
          @trade.approved_by = approval_actor
          @trade.deny!
          render json: trade_json(@trade), trail: @trade
        else
          render json: { error: "Cannot deny trade in #{@trade.status} state" }, status: :unprocessable_entity
        end
      end

      # POST /api/v1/trades/:id/pass
      def pass
        if @trade.may_pass?
          @trade.pass!
          render json: trade_json(@trade), trail: @trade
        else
          render json: { error: "Cannot pass trade in #{@trade.status} state" }, status: :unprocessable_entity
        end
      end

      # POST /api/v1/trades/:id/cancel
      def cancel
        result = Trades::CancellationService.new(@trade, cancellation_params).call

        if result.success?
          render json: trade_json(result.trade), trail: result.trade
        else
          render json: { error: result.error, details: result.details }, status: :unprocessable_entity
        end
      end

      # POST /api/v1/trades/:id/confirm
      def confirm
        was_unconfirmed = @trade.confirmed_at.blank?
        @trade.confirmed_at = Time.current
        @trade.save!

        if was_unconfirmed && (@trade.APPROVED? || @trade.QUEUED?)
          Trades::ExecutionSchedulerService.new(@trade).call
        end

        render json: trade_json(@trade), trail: @trade
      end

      # POST /api/v1/trades/:id/execute
      def execute
        result = TradeExecutionService.new(@trade, execution_params).call

        if result.success?
          render json: trade_json(result.trade), trail: result.trade
        else
          render json: { error: result.error, details: result.details }, status: :unprocessable_entity
        end
      end

      # POST /api/v1/trades/:id/fill
      def fill
        unless @trade.may_fill? || @trade.may_complete_fill? || @trade.may_partial_fill?
          render json: { error: "Cannot fill trade in #{@trade.status} state" }, status: :unprocessable_entity
          return
        end

        fill_attrs = fill_params
        qty_filled = fill_attrs[:qty_filled].to_f

        if qty_filled <= 0
          render json: { error: "qty_filled must be greater than 0" }, status: :unprocessable_entity
          return
        end

        # Require at least one way to price the fill. If avg_fill_price is omitted,
        # derive it from filled_value so audit fields remain complete.
        avg_fill_price = fill_attrs[:avg_fill_price].presence&.to_f
        if avg_fill_price.nil?
          filled_value = fill_attrs[:filled_value].presence&.to_f
          if filled_value.nil?
            render json: { error: "avg_fill_price or filled_value is required" }, status: :unprocessable_entity
            return
          end
          avg_fill_price = filled_value / qty_filled
        end

        result = Trades::FillProcessorService.new(@trade).process_fill(
          qty_filled: qty_filled,
          avg_fill_price: avg_fill_price,
          alpaca_order_id: fill_attrs[:alpaca_order_id],
          final: fill_final?(fill_attrs[:final], qty_filled)
        )

        render json: trade_json(@trade.reload).merge(
          fill: {
            delta_qty: result[:delta_qty],
            delta_value: result[:delta_value],
            filled_value: result[:filled_value]
          }
        ), trail: @trade
      rescue ActiveRecord::RecordInvalid => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      # POST /api/v1/trades/:id/fail
      def fail
        if @trade.may_fail?
          @trade.execution_error = params[:error]
          @trade.fail!
          render json: trade_json(@trade), trail: @trade
        else
          render json: { error: "Cannot fail trade in #{@trade.status} state" }, status: :unprocessable_entity
        end
      end

      private

      def set_trade
        # Support both numeric IDs and trade_id strings (e.g., "logan-1770071877-bd6eddfb")
        if params[:id].to_s =~ /^\d+$/
          # Numeric ID
          @trade = Trade.includes(:agent, :trade_events).find(params[:id])
        else
          # trade_id string
          @trade = Trade.includes(:agent, :trade_events).find_by!(trade_id: params[:id])
        end
      rescue ActiveRecord::RecordNotFound
        render json: { error: "Trade not found" }, status: :not_found
      end

      def trade_params
        permitted = params.require(:trade).permit(
          :agent_id, :ticker, :side, :qty_requested, :amount_requested,
          :order_type, :limit_price, :stop_price, :trail_percent, :trail_amount,
          :manual_trail_percent, :manual_trail_amount,
          :thesis, :stop_loss, :target_price, :is_urgent, :extended_hours,
          :asset_class, :execution_policy,
          :request_id, :source, :source_message_id  # Idempotency support
        ).to_h.symbolize_keys

        requested_agent_id = permitted[:agent_id].to_s.presence
        if current_api_principal&.agent?
          if requested_agent_id.present? && requested_agent_id != current_api_principal.id.to_s
            render json: { error: "Forbidden", details: { agent_id: "does not match authenticated caller" } }, status: :forbidden
            return nil
          end

          permitted[:agent_id] = current_api_principal.id
        elsif requested_agent_id.blank?
          render json: { error: "agent_id is required" }, status: :unprocessable_entity
          return nil
        end

        agent = Agent.find_by(agent_id: permitted[:agent_id].to_s)
        unless agent
          render json: { error: "Unknown agent", details: { agent_id: permitted[:agent_id] } }, status: :unprocessable_entity
          return nil
        end

        permitted[:agent] = agent
        permitted.delete(:agent_id)
        merge_advisory_trail_notes!(permitted)
        permitted[:source] ||= current_api_principal&.internal? ? "api_internal" : "api"
        permitted
      end

      def merge_advisory_trail_notes!(params_hash)
        fragments = advisory_trail_fragments_from!(
          params_hash,
          percent_key: :manual_trail_percent,
          amount_key: :manual_trail_amount
        )

        order_type = params_hash[:order_type].presence.to_s.upcase
        order_type = "MARKET" if order_type.blank?

        if order_type != "TRAILING_STOP"
          fragments.concat(
            advisory_trail_fragments_from!(
              params_hash,
              percent_key: :trail_percent,
              amount_key: :trail_amount
            )
          )
        end

        return if fragments.empty?

        advisory_note = "Advisory trailing plan: #{fragments.uniq.join('; ')}."
        params_hash[:thesis] = [params_hash[:thesis].presence, advisory_note].compact.join("\n")
      end

      def advisory_trail_fragments_from!(params_hash, percent_key:, amount_key:)
        fragments = []

        trail_percent = params_hash.delete(percent_key).to_s.strip
        fragments << "manual trail #{trail_percent}%" if trail_percent.present?

        trail_amount = params_hash.delete(amount_key).to_s.strip
        fragments << "manual trail $#{trail_amount}" if trail_amount.present?

        fragments
      end

      def execution_params
        params.permit(:executed_by, :alpaca_order_id)
      end

      def cancellation_params
        permitted = params.permit(:cancelled_by, :reason).to_h.symbolize_keys
        return permitted if current_api_principal&.internal?

        permitted[:cancelled_by] = current_api_principal.id
        permitted
      end

      def fill_params
        params.permit(:qty_filled, :avg_fill_price, :filled_value, :alpaca_order_id, :final)
      end

      def fill_final?(raw_final, qty_filled)
        return ActiveModel::Type::Boolean.new.cast(raw_final) unless raw_final.nil?

        requested = @trade.qty_requested.to_f
        return true if requested <= 0

        qty_filled >= requested
      end

      def notify_trade_proposal_failure(proposal_params, error_message, details)
        details_hash = details.to_h.with_indifferent_access
        agent_id = proposal_params[:agent]&.agent_id.to_s
        agent_id = proposal_params[:agent_id].to_s if agent_id.blank?
        agent_id = "unknown" if agent_id.blank?
        ticker = proposal_params[:ticker].to_s.upcase.presence || "?"
        side = proposal_params[:side].to_s.upcase.presence || "?"
        request_id = details_hash[:request_id].to_s

        dedupe_basis = request_id.presence || "#{agent_id}:#{ticker}:#{side}:#{error_message.to_s.truncate(80)}"
        dedupe_key = "proposal-failure:#{dedupe_basis}"
        return unless NotificationDedupeService.allow?(dedupe_key, ttl_seconds: AppConfig.discord_notification_dedupe_seconds)

        requester_mention = News::AgentMentions.mention_for(agent_id)
        requester = requester_mention.present? ? "#{requester_mention} (#{agent_id})" : agent_id

        lines = [
          "[PROPOSAL FAILED] #{request_id.presence || 'no-request-id'}",
          "**#{side} #{ticker}**",
          "Requester: #{requester}",
          "Reason: #{error_message}",
          "Next: #{proposal_failure_next_step(requester, details_hash)}"
        ]

        DiscordService.post_to_trading_floor(content: lines.join("\n"))
      rescue StandardError => e
        Rails.logger.error("Failed to notify proposal failure: #{e.class}: #{e.message}")
      end

      def proposal_failure_next_step(requester, details_hash)
        case details_hash[:guard].to_s
        when "missing_sizing"
          "#{requester} add qty_requested or amount_requested (tiny test: qty_requested 1) and use propose_trade to resubmit immediately."
        when "market_order_params"
          "#{requester} remove invalid MARKET order execution fields and use propose_trade to resubmit immediately."
        else
          if ActiveModel::Type::Boolean.new.cast(details_hash[:immediate_retry_allowed])
            "#{requester} correct inputs and use propose_trade to resubmit immediately."
          else
            "#{requester} fix inputs and use propose_trade to resubmit."
          end
        end
      end

      def trade_json(trade)
        {
          id: trade.id,
          trade_id: trade.trade_id,
          agent_id: trade.agent.agent_id,
          ticker: trade.ticker,
          side: trade.side,
          qty_requested: trade.qty_requested,
          amount_requested: trade.amount_requested,
          order_type: trade.order_type,
          limit_price: trade.limit_price,
          stop_price: trade.stop_price,
          trail_percent: trade.trail_percent,
          trail_amount: trade.trail_amount,
          status: trade.status,
          thesis: trade.thesis,
          stop_loss: trade.stop_loss,
          target_price: trade.target_price,
          is_urgent: trade.is_urgent,
          approved_by: trade.approved_by,
          approved_at: trade.approved_at,
          confirmed_at: trade.confirmed_at,
          denial_reason: trade.denial_reason,
          execution_error: trade.execution_error,
          executed_by: trade.executed_by,
          execution_started_at: trade.execution_started_at,
          execution_completed_at: trade.execution_completed_at,
          alpaca_order_id: trade.alpaca_order_id,
          qty_filled: trade.qty_filled,
          avg_fill_price: trade.avg_fill_price,
          filled_value: trade.filled_value,
          extended_hours: trade.extended_hours,
          asset_class: trade.asset_class,
          execution_policy: trade.execution_policy,
          queued_at: trade.queued_at,
          scheduled_for: trade.scheduled_for,
          next_action: Trades::NextActionService.new(trade).as_json,
          created_at: trade.created_at,
          updated_at: trade.updated_at,
          events_count: trade.trade_events.size
        }
      end

      def approval_actor
        return current_api_principal.id unless current_api_principal&.internal?

        params[:approved_by].presence || "tiverton"
      end

      def require_trade_owner_or_internal_for_pass_or_confirm!
        require_trade_owner_or_internal_api_principal!(@trade)
      end

      def require_trade_cancel_authorization!
        require_trade_owner_or_internal_api_principal!(@trade, allow_coordinator: true)
      end
    end
  end
end
