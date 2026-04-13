module Api
  module V1
    class PositionsController < ApplicationController
      trail_tool :index, scope: :agent, name: "get_positions",
        description: "List current positions with an optional agent filter.",
        query: {
          agent_id: { type: "string", description: "Filter to a specific trader" }
        }

      before_action :require_internal_api_principal!, only: [ :update, :revalue, :cleanup_dust ]

      # GET /api/v1/positions
      def index
        if LedgerMigration.read_from_ledger?
          render_ledger_positions
        else
          render_legacy_positions
        end
      end

      # GET /api/v1/positions/:id
      def show
        @position = Position.includes(:agent).find(params[:id])

        render json: position_json(@position)
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Position not found' }, status: :not_found
      end

      # PATCH /api/v1/positions/:id
      # Live risk-management fields for open positions.
      # In ledger mode, ID can be "agent_id:ticker" (e.g., "weston:ARM")
      def update
        position = find_position_for_update(params[:id])

        unless position
          render json: { error: 'Position not found', docs_hint: risk_docs_hint }, status: :not_found
          return
        end

        if position.update(position_update_params)
          render json: position_json(position).merge(docs_hint: risk_docs_hint)
        else
          render json: { error: position.errors.full_messages.join(', '), docs_hint: risk_docs_hint }, status: :unprocessable_entity
        end
      end

      # PATCH /api/v1/positions/revalue
      # Batch update current_value for all positions (called by price update job)
      def revalue
        prices = params[:prices] # { 'AAPL' => 150.25, 'GOOGL' => 2800.50 }

        updated_count = 0
        errors = []

        Position.open_positions.each do |position|
          if prices[position.ticker]
            new_value = position.qty * prices[position.ticker].to_f
            position.update(current_value: new_value)
            updated_count += 1
          else
            errors << "No price for #{position.ticker}"
          end
        end

        render json: {
          updated: updated_count,
          errors: errors,
          timestamp: Time.current
        }
      end

      # POST /api/v1/positions/cleanup_dust
      # Remove dust positions (qty < threshold or value < $1)
      def cleanup_dust
        threshold_qty = (params[:threshold_qty] || 0.01).to_f
        threshold_value = (params[:threshold_value] || 1.0).to_f
        dry_run = params[:dry_run] == 'true'

        # qty is stored as integer in DB; cast to float for fractional threshold comparisons
        dust = Position.where('ABS(qty)::float < ? OR current_value < ?', threshold_qty, threshold_value)

        if dry_run
          render json: {
            dry_run: true,
            would_delete: dust.count,
            positions: dust.map { |p| position_json(p) }
          }
        else
          deleted_positions = dust.map { |p| position_json(p) }
          count = dust.destroy_all.count

          render json: {
            dry_run: false,
            deleted: count,
            positions: deleted_positions
          }
        end
      end

      private

      # Find position for update - supports both numeric ID and "agent_id:ticker" format
      def find_position_for_update(identifier)
        # Try numeric ID first
        if identifier.to_s.match?(/^\d+$/)
          return Position.includes(:agent).find_by(id: identifier)
        end

        # Parse "agent_id:ticker" format
        parts = identifier.to_s.split(':', 2)
        return nil unless parts.size == 2

        agent_id_str = parts[0]
        ticker = parts[1].upcase

        agent = Agent.find_by(agent_id: agent_id_str)
        return nil unless agent

        # In ledger mode, find or create Position record (stop_loss lives here)
        if LedgerMigration.read_from_ledger?
          position = Position.find_or_initialize_by(agent_id: agent.id, ticker: ticker)
          
          # If creating new Position, populate from ledger projection
          if position.new_record?
            projection = Ledger::ProjectionService.new
            ledger_pos = projection.position_for(agent, ticker)
            
            if ledger_pos
              position.assign_attributes(
                qty: ledger_pos[:qty],
                avg_entry_price: ledger_pos[:avg_cost_per_share],
                asset_class: infer_asset_class(ticker),
                opened_at: Time.current,
                stop_loss: 0.01 # Temporary default to satisfy constraint
              )
              position.save!
            else
              return nil # No ledger position exists
            end
          end
          
          position
        else
          # Legacy mode: just find existing position
          Position.find_by(agent_id: agent.id, ticker: ticker)
        end
      end

      def render_legacy_positions
        @positions = Position.includes(:agent).open_positions

        if params[:agent_id]
          agent = Agent.find_by(agent_id: params[:agent_id])
          @positions = agent ? @positions.where(agent_id: agent.id) : @positions.none
        end

        render json: {
          positions: @positions.map { |position| position_json(position) },
          source: 'legacy'
        }
      end

      def render_ledger_positions
        projection = Ledger::ProjectionService.new

        positions = if params[:agent_id]
                      projection.positions_for_agent(params[:agent_id])
                    else
                      Agent.all.flat_map { |agent| projection.positions_for_agent(agent) }
                    end

        # Fetch latest prices for all position tickers
        tickers = positions.map { |p| p[:ticker] }.uniq
        latest_prices = fetch_latest_prices(tickers)

        # Enrich positions with calculated market values and IDs
        enriched = positions.map do |pos|
          price = latest_prices[pos[:ticker]]
          current_value = price ? (pos[:qty].to_f * price) : nil
          unrealized_pnl = current_value ? (current_value - pos[:cost_basis].to_f) : nil
          
          # Generate composite ID for ledger positions (agent_id:ticker)
          # This allows the update endpoint to work without a database Position.id
          composite_id = "#{pos[:agent_id]}:#{pos[:ticker]}"

          pos.merge(
            id: composite_id,
            asset_class: infer_asset_class(pos[:ticker]),
            current_price: price,
            current_value: current_value,
            unrealized_pnl: unrealized_pnl,
            unrealized_pnl_percentage: calculate_pnl_percentage(unrealized_pnl, pos[:cost_basis])
          )
        end

        render json: {
          positions: enriched,
          source: 'ledger',
          as_of: projection.as_of
        }
      end

      # Fetch latest prices from price samples or Alpaca
      def fetch_latest_prices(tickers)
        return {} if tickers.empty?

        # Get latest price sample for each ticker
        prices = {}
        tickers.each do |ticker|
          sample = PriceSample.where(ticker: ticker).order(sampled_at: :desc).first
          prices[ticker] = sample&.price&.to_f
        end

        # For tickers without recent price samples, fetch from Alpaca
        missing_tickers = tickers.select { |t| prices[t].nil? || prices[t] <= 0 }
        if missing_tickers.any?
          begin
            broker = Alpaca::BrokerService.new
            missing_tickers.each do |ticker|
              result = broker.get_quote(ticker: ticker, side: 'BUY', quiet: true)
              if result[:success]
                price = result[:price].presence || result[:last]
                prices[ticker] = price.to_f if price.present?
              end
            end
          rescue StandardError => e
            Rails.logger.warn("PositionsController: Failed to fetch prices from Alpaca: #{e.message}")
          end
        end

        prices
      end

      # Infer asset class from ticker format
      def infer_asset_class(ticker)
        return 'crypto' if ticker.to_s.include?('/')
        return 'us_option' if ticker.to_s.match?(/\A[A-Z]{1,6}\d{6}[CP]\d{8}\z/)
        'us_equity'
      end

      # Calculate P&L percentage
      def calculate_pnl_percentage(unrealized_pnl, cost_basis)
        return nil if unrealized_pnl.nil? || cost_basis.to_f.zero?
        (unrealized_pnl / cost_basis.to_f) * 100
      end

      def position_json(position)
        {
          id: position.id,
          agent_id: position.agent.agent_id,
          agent_name: position.agent.name,
          ticker: position.ticker,
          qty: position.qty,
          avg_entry_price: position.avg_entry_price,
          stop_loss: position.stop_loss,
          stop_loss_triggered_at: position.stop_loss_triggered_at,
          stop_loss_last_alert_at: position.stop_loss_last_alert_at,
          stop_loss_alert_count: position.stop_loss_alert_count,
          asset_class: position.asset_class,
          current_value: position.current_value,
          cost_basis: position.cost_basis,
          unrealized_pnl: position.unrealized_pnl,
          unrealized_pnl_percentage: position.unrealized_pnl_percentage,
          opened_at: position.opened_at,
          updated_at: position.updated_at
        }
      end

      def position_update_params
        params.permit(:stop_loss)
      end

      def risk_docs_hint
        'Docs: <legacy-shared-root>/skills/trade.md (Live Stop Management)'
      end
    end
  end
end
