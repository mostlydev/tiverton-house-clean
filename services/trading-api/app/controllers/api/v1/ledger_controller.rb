# frozen_string_literal: true

module Api
  module V1
    # API endpoints for ledger-derived data.
    # These read from the immutable ledger rather than legacy mutable tables.
    class LedgerController < ApplicationController
      # GET /api/v1/ledger/positions
      # GET /api/v1/ledger/positions?agent_id=dundas
      # GET /api/v1/ledger/positions?agent_id=dundas&as_of=2026-02-04T12:00:00Z
      def positions
        projection = Ledger::ProjectionService.new(as_of: parse_as_of)

        if params[:agent_id].present?
          positions = projection.positions_for_agent(params[:agent_id])
          render json: {
            agent_id: params[:agent_id],
            positions: positions,
            count: positions.size,
            source: 'ledger',
            as_of: projection.as_of
          }
        else
          # All positions grouped by agent
          all_positions = Agent.all.flat_map do |agent|
            projection.positions_for_agent(agent)
          end

          render json: {
            positions: all_positions,
            count: all_positions.size,
            source: 'ledger',
            as_of: projection.as_of
          }
        end
      end

      # GET /api/v1/ledger/positions/:ticker
      # GET /api/v1/ledger/positions/:ticker?agent_id=dundas
      def position
        projection = Ledger::ProjectionService.new(as_of: parse_as_of)
        ticker = params[:ticker]&.upcase

        if params[:agent_id].present?
          position = projection.position_for(params[:agent_id], ticker)
          if position
            render json: position
          else
            render json: { error: 'Position not found' }, status: :not_found
          end
        else
          # All positions for this ticker across agents
          positions = Agent.all.filter_map do |agent|
            projection.position_for(agent, ticker)
          end

          render json: {
            ticker: ticker,
            positions: positions,
            total_qty: positions.sum { |p| p[:qty] },
            source: 'ledger',
            as_of: projection.as_of
          }
        end
      end

      # GET /api/v1/ledger/wallets
      # GET /api/v1/ledger/wallets/:agent_id
      def wallets
        projection = Ledger::ProjectionService.new(as_of: parse_as_of)

        if params[:agent_id].present?
          wallet = projection.wallet_for_agent(params[:agent_id])
          if wallet
            render json: wallet
          else
            render json: { error: 'Wallet not found' }, status: :not_found
          end
        else
          wallets = projection.all_wallets
          render json: {
            wallets: wallets,
            total_cash: wallets.sum { |w| w[:cash] },
            source: 'ledger',
            as_of: projection.as_of
          }
        end
      end

      # GET /api/v1/ledger/portfolio/:agent_id
      def portfolio
        projection = Ledger::ProjectionService.new(as_of: parse_as_of)
        portfolio = projection.portfolio_for_agent(params[:agent_id])

        if portfolio
          render json: portfolio
        else
          render json: { error: 'Agent not found' }, status: :not_found
        end
      end

      # GET /api/v1/ledger/explain/:ticker?agent_id=dundas
      def explain
        projection = Ledger::ProjectionService.new(as_of: parse_as_of)

        unless params[:agent_id].present?
          render json: { error: 'agent_id is required' }, status: :bad_request
          return
        end

        explanation = projection.explain_position(params[:agent_id], params[:ticker])

        if explanation && explanation[:lots].any?
          render json: explanation
        else
          render json: { error: 'Position not found' }, status: :not_found
        end
      end

      # GET /api/v1/ledger/cash_history/:agent_id
      def cash_history
        projection = Ledger::ProjectionService.new(as_of: parse_as_of)
        limit = [params[:limit]&.to_i || 50, 200].min

        history = projection.cash_history(params[:agent_id], limit: limit)

        render json: {
          agent_id: params[:agent_id],
          transactions: history,
          count: history.size,
          source: 'ledger',
          as_of: projection.as_of
        }
      end

      # GET /api/v1/ledger/audit/trade/:trade_id
      def audit_trade
        trade = Trade.find_by(id: params[:trade_id]) || Trade.find_by(trade_id: params[:trade_id])

        unless trade
          render json: { error: 'Trade not found' }, status: :not_found
          return
        end

        render json: build_trade_audit(trade)
      end

      # GET /api/v1/ledger/stats
      def stats
        render json: {
          ledger_transactions: LedgerTransaction.count,
          ledger_entries: LedgerEntry.count,
          position_lots: {
            total: PositionLot.count,
            open: PositionLot.where(closed_at: nil).count,
            closed: PositionLot.where.not(closed_at: nil).count,
            bootstrap: PositionLot.where(bootstrap_adjusted: true).count
          },
          broker_fills: {
            total: BrokerFill.count,
            verified: BrokerFill.where(fill_id_confidence: 'broker_verified').count,
            order_derived: BrokerFill.where(fill_id_confidence: 'order_derived').count
          }
        }
      end

      private

      def parse_as_of
        return nil unless params[:as_of].present?
        Time.parse(params[:as_of])
      rescue ArgumentError
        nil
      end

      def build_trade_audit(trade)
        # Collect all related records
        broker_order = BrokerOrder.find_by(trade: trade)
        broker_fills = BrokerFill.where(trade: trade).order(:executed_at)
        ledger_txns = LedgerTransaction.where(source_type: 'BrokerFill', source_id: broker_fills.pluck(:id))

        {
          trade: {
            id: trade.id,
            trade_id: trade.trade_id,
            ticker: trade.ticker,
            side: trade.side,
            status: trade.status,
            qty_requested: trade.qty_requested,
            qty_filled: trade.qty_filled,
            avg_fill_price: trade.avg_fill_price,
            created_at: trade.created_at,
            updated_at: trade.updated_at
          },
          broker_order: broker_order&.slice(:id, :broker_order_id, :client_order_id, :status, :submitted_at, :filled_at),
          broker_fills: broker_fills.map { |f| f.slice(:id, :broker_fill_id, :qty, :price, :executed_at, :fill_id_confidence) },
          ledger_transactions: ledger_txns.map { |t| { id: t.id, ledger_txn_id: t.ledger_txn_id, booked_at: t.booked_at, description: t.description } },
          timeline: build_timeline(trade, broker_order, broker_fills, ledger_txns)
        }
      end

      def build_timeline(trade, broker_order, broker_fills, ledger_txns)
        events = []

        events << { at: trade.created_at, type: 'trade_created', status: 'PROPOSED' }
        events << { at: trade.approved_at, type: 'trade_approved' } if trade.approved_at
        events << { at: trade.executed_at, type: 'trade_executed' } if trade.executed_at

        if broker_order
          events << { at: broker_order.submitted_at, type: 'order_submitted', broker_order_id: broker_order.broker_order_id } if broker_order.submitted_at
          events << { at: broker_order.filled_at, type: 'order_filled' } if broker_order.filled_at
        end

        broker_fills.each do |fill|
          events << { at: fill.executed_at, type: 'fill', qty: fill.qty, price: fill.price, confidence: fill.fill_id_confidence }
        end

        ledger_txns.each do |txn|
          events << { at: txn.booked_at, type: 'ledger_posted', txn_id: txn.ledger_txn_id }
        end

        events.sort_by { |e| e[:at] || Time.at(0) }
      end
    end
  end
end
