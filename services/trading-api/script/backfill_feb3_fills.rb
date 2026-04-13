#!/usr/bin/env ruby
# frozen_string_literal: true

# Backfill Feb 3-4 broker fills from saved Alpaca data
#
# Usage:
#   DRY_RUN=true bundle exec ruby script/backfill_feb3_fills.rb  # Preview only
#   bundle exec ruby script/backfill_feb3_fills.rb                # Live run

require_relative '../config/environment'
require 'json'

class Feb3FillsBackfill
  FILLS_FILE = '<operator-home>/alpaca-historical-fills.json'
  PROVENANCE_ID = 'feb3-4-fills-backfill-2026'

  def initialize(dry_run: false)
    @dry_run = dry_run
    @stats = {
      total: 0,
      created: 0,
      skipped: 0,
      errors: 0,
      sells: 0,
      lots_closed: 0,
      realized_pnl: 0.0
    }
  end

  def run
    print_header
    load_fills
    # Skip provenance creation - not critical for backfill
    # create_provenance unless @dry_run
    process_fills
    print_summary
  end

  private

  def print_header
    puts "Feb 3-4 Fills Backfill"
    puts "Mode: #{@dry_run ? 'DRY RUN' : 'LIVE'}"
    puts "=" * 80
  end

  def load_fills
    unless File.exist?(FILLS_FILE)
      puts "ERROR: Fills file not found at #{FILLS_FILE}"
      exit 1
    end

    data = JSON.parse(File.read(FILLS_FILE))
    @fills = data['fills'] || []
    @stats[:total] = @fills.size

    puts "Loaded #{@stats[:total]} fills from #{FILLS_FILE}"

    if @fills.any?
      dates = @fills.map { |f| f['transaction_time'] }.sort
      puts "Date range: #{dates.first} to #{dates.last}"
    end

    puts
  end

  def create_provenance
    return if ReconciliationProvenance.exists?(run_id: PROVENANCE_ID)

    ReconciliationProvenance.create!(
      run_id: PROVENANCE_ID,
      runner_script: 'backfill_feb3_fills.rb',
      invocation_params: {
        fills_file: FILLS_FILE,
        total_fills: @stats[:total]
      },
      operator: 'system',
      status: 'completed'
    )
  end

  def process_fills
    @fills.each_with_index do |fill_data, idx|
      process_fill(fill_data, idx + 1)
    end
  end

  def process_fill(fill_data, num)
    @stats[:sells] += 1 if fill_data['side'] == 'sell'

    # Check if already exists
    if BrokerFill.exists?(broker_fill_id: fill_data['id'])
      puts "[#{num}/#{@stats[:total]}] SKIP: #{fill_data['symbol']} #{fill_data['side']} (already exists)"
      @stats[:skipped] += 1
      return
    end

    # Resolve agent
    agent = resolve_agent(fill_data)
    unless agent
      puts "[#{num}/#{@stats[:total]}] ERROR: No agent found for order #{fill_data['order_id']}"
      @stats[:errors] += 1
      return
    end

    # Ingest fill
    if @dry_run
      puts "[#{num}/#{@stats[:total]}] WOULD CREATE: #{fill_data['symbol']} #{fill_data['side']} #{fill_data['qty']} @ #{fill_data['price']} (agent: #{agent.agent_id})"
      @stats[:created] += 1
    else
      result = ingest_fill(fill_data, agent)

      if result.success
        puts "[#{num}/#{@stats[:total]}] OK: #{fill_data['symbol']} #{fill_data['side']} #{fill_data['qty']} @ #{fill_data['price']}"
        @stats[:created] += 1

        # Track P&L if this was a sell
        if fill_data['side'] == 'sell'
          closed_lots = PositionLot.closed.where(close_source_type: 'BrokerFill', close_source_id: result.fill.id)
          @stats[:lots_closed] += closed_lots.count
          @stats[:realized_pnl] += closed_lots.sum(:realized_pnl).to_f
        end
      else
        puts "[#{num}/#{@stats[:total]}] ERROR: #{fill_data['symbol']} - #{result.errors.join(', ')}"
        @stats[:errors] += 1
      end
    end

  rescue StandardError => e
    puts "[#{num}/#{@stats[:total]}] EXCEPTION: #{e.message}"
    @stats[:errors] += 1
  end

  def resolve_agent(fill_data)
    # Try to find agent from broker order
    broker_order = BrokerOrder.find_by(broker_order_id: fill_data['order_id'])
    return broker_order.agent if broker_order&.agent

    # Try to find agent from trade
    trade = Trade.where(ticker: fill_data['symbol'])
                 .where("updated_at BETWEEN ? AND ?", '2026-02-03', '2026-02-05')
                 .first
    return trade.agent if trade&.agent

    # Fallback: try agent mapping (for orphaned orders)
    agent_mapping = load_agent_mapping
    agent_id = agent_mapping[fill_data['order_id']]
    Agent.find_by(agent_id: agent_id) if agent_id
  end

  def load_agent_mapping
    mapping_file = Rails.root.join('config', 'feb3_agent_mapping.yml')
    return {} unless File.exist?(mapping_file)

    YAML.load_file(mapping_file) || {}
  rescue StandardError
    {}
  end

  def ingest_fill(fill_data, agent)
    service = Broker::FillIngestionService.new

    service.ingest!(
      broker_fill_id: fill_data['id'],
      broker_order_id: fill_data['order_id'],
      agent: agent,
      ticker: fill_data['symbol'],
      side: fill_data['side'],
      qty: fill_data['qty'].to_f,
      price: fill_data['price'].to_f,
      executed_at: Time.parse(fill_data['transaction_time']),
      fill_id_confidence: 'broker_verified',
      raw_fill: fill_data
    )
  end

  def print_summary
    puts
    puts "=" * 80
    puts "BACKFILL SUMMARY"
    puts "=" * 80
    puts "Total fills:      #{@stats[:total]}"
    puts "Created:          #{@stats[:created]}"
    puts "Skipped:          #{@stats[:skipped]}  (already exist)"
    puts "Errors:           #{@stats[:errors]}"
    puts "Sell fills:       #{@stats[:sells]}"

    unless @dry_run
      puts "Lots closed:      #{@stats[:lots_closed]}"
      puts "Realized P&L:     $#{@stats[:realized_pnl].round(2)}"
    end

    puts "=" * 80
  end
end

# Run the backfill
dry_run = ENV['DRY_RUN'] == 'true'
backfill = Feb3FillsBackfill.new(dry_run: dry_run)
backfill.run
