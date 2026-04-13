# frozen_string_literal: true

namespace :db do
  desc "Migrate data from SQLite to PostgreSQL"  
  task migrate_from_sqlite: :environment do
    if LedgerMigration.ledger_only_writes?
      puts "ERROR: Migration task blocked — system is in ledger-only mode."
      exit 1
    end

    require 'sqlite3'

    sqlite_path = ENV['SQLITE_PATH'] || File.expand_path('<legacy-shared-root>/trading.db')
    
    puts "=" * 60
    puts "SQLite to PostgreSQL Migration"
    puts "=" * 60
    puts "Source: #{sqlite_path}"
    puts "Target: #{ActiveRecord::Base.connection_db_config.database}"
    puts ""

    unless File.exist?(sqlite_path)
      puts "❌ SQLite database not found at: #{sqlite_path}"
      exit 1
    end

    sqlite_db = SQLite3::Database.new(sqlite_path)
    sqlite_db.results_as_hash = true

    # Count records in SQLite
    puts "Counting SQLite records..."
    counts = {
      agents: sqlite_db.execute("SELECT COUNT(*) FROM agents")[0][0],
      wallets: sqlite_db.execute("SELECT COUNT(*) FROM wallets")[0][0],
      trades: sqlite_db.execute("SELECT COUNT(*) FROM trades")[0][0],
      positions: sqlite_db.execute("SELECT COUNT(*) FROM positions")[0][0],
      trade_events: sqlite_db.execute("SELECT COUNT(*) FROM trade_events")[0][0],
      price_samples: sqlite_db.execute("SELECT COUNT(*) FROM price_samples")[0][0]
    }

    puts "SQLite record counts:"
    counts.each { |table, count| puts "  #{table}: #{count}" }
    puts ""

    print "⚠️  This will DELETE all existing PostgreSQL data. Continue? [y/N] "
    response = STDIN.gets.chomp
    unless response.downcase == 'y'
      puts "Aborted."
      exit 0
    end

    ActiveRecord::Base.transaction do
      puts "\n🗑️  Clearing PostgreSQL data..."
      TradeEvent.delete_all
      Trade.delete_all
      Position.delete_all
      Wallet.delete_all
      Agent.delete_all
      ActiveRecord::Base.connection.execute("TRUNCATE price_samples RESTART IDENTITY CASCADE")

      # Migrate Agents (SQLite uses text ID, Rails uses integer ID)
      puts "\n📋 Migrating agents..."
      agent_id_map = {}  # SQLite id (text) => Rails id (integer)
      
      agents = sqlite_db.execute("SELECT * FROM agents ORDER BY id")
      agents.each do |row|
        agent = Agent.create!(
          agent_id: row['id'],  # SQLite's "id" becomes Rails' "agent_id"
          name: row['name'],
          role: row['role'],
          style: row['style'],
          status: row['status'],
          created_at: row['created_at'],
          updated_at: row['updated_at']
        )
        agent_id_map[row['id']] = agent.id
      end
      puts "  ✓ Migrated #{Agent.count} agents"

      # Migrate Wallets (uses agent_id as PK in SQLite)
      puts "\n💰 Migrating wallets..."
      wallets = sqlite_db.execute("SELECT * FROM wallets")
      wallets.each do |row|
        rails_agent_id = agent_id_map[row['agent_id']]
        next unless rails_agent_id

        Wallet.create!(
          agent_id: rails_agent_id,
          wallet_size: row['wallet_size'],
          cash: row['cash'],
          invested: row['invested'],
          created_at: Time.current,
          updated_at: row['updated_at']
        )
      end
      puts "  ✓ Migrated #{Wallet.count} wallets"

      # Migrate Trades (SQLite id => Rails trade_id, skip validations)
      puts "\n📊 Migrating trades..."
      trades = sqlite_db.execute("SELECT * FROM trades ORDER BY created_at")
      trades.each do |row|
        rails_agent_id = agent_id_map[row['agent_id']]
        next unless rails_agent_id

        # Map qty columns (SQLite has qty_requested/qty_filled plus legacy *_old)
        qty_requested = row['qty_requested']
        qty_requested = row['qty_requested_old'] if qty_requested.nil?
        qty_filled = row['qty_filled']
        qty_filled = row['qty_filled_old'] if qty_filled.nil?

        trade = Trade.new(
          trade_id: row['id'],  # SQLite's "id" becomes Rails' "trade_id"
          agent_id: rails_agent_id,
          ticker: row['ticker'],
          side: row['side'],
          order_type: row['order_type'],
          qty_requested: qty_requested,
          amount_requested: row['amount_requested'],
          limit_price: row['limit_price'],
          stop_price: row['stop_price'],
          trail_percent: row['trail_percent'],
          trail_amount: row['trail_amount'],
          thesis: row['thesis'],
          stop_loss: row['stop_loss'],
          target_price: row['target_price'],
          is_urgent: row['is_urgent'] == 1,
          status: row['status'],
          approved_by: row['approved_by'],
          approved_at: row['approved_at'],
          confirmed_at: row['confirmed_at'],
          executed_by: row['executed_by'],
          execution_started_at: row['execution_started_at'],
          execution_completed_at: row['execution_completed_at'],
          alpaca_order_id: row['alpaca_order_id'],
          qty_filled: qty_filled,
          avg_fill_price: row['avg_fill_price'],
          filled_value: row['filled_value'],
          execution_error: row['execution_error'],
          denial_reason: row['denial_reason'],
          created_at: row['created_at'],
          updated_at: row['updated_at']
        )
        trade.save(validate: false)
      end
      puts "  ✓ Migrated #{Trade.count} trades"

      # Migrate Positions
      puts "\n📈 Migrating positions..."
      positions = sqlite_db.execute("SELECT * FROM positions ORDER BY opened_at")
      positions.each do |row|
        rails_agent_id = agent_id_map[row['agent_id']]
        next unless rails_agent_id

        Position.create!(
          agent_id: rails_agent_id,
          ticker: row['ticker'],
          qty: row['qty'],
          avg_entry_price: row['avg_entry_price'],
          current_value: row['current_value'],
          opened_at: row['opened_at'],
          updated_at: row['updated_at']
        )
      end
      puts "  ✓ Migrated #{Position.count} positions"

      # Migrate Trade Events (SQLite trade_id is TEXT, need to match)
      puts "\n📝 Migrating trade events..."
      events = sqlite_db.execute("SELECT * FROM trade_events ORDER BY created_at")
      events.each do |row|
        # Find the Rails trade by trade_id (which came from SQLite's id column)
        trade = Trade.find_by(trade_id: row['trade_id'])
        next unless trade

        TradeEvent.create!(
          trade_id: trade.id,  # Rails internal ID
          event_type: row['event_type'],
          actor: row['actor'],
          details: JSON.parse(row['details'] || '{}'),
          created_at: row['created_at'],
          updated_at: row['created_at']
        )
      end
      puts "  ✓ Migrated #{TradeEvent.count} trade events"

      # Migrate Price Samples (batch insert for performance)
      puts "\n💹 Migrating price samples (#{counts[:price_samples]} records)..."
      batch_size = 1000
      offset = 0
      total_inserted = 0

      loop do
        samples = sqlite_db.execute("SELECT * FROM price_samples ORDER BY id LIMIT #{batch_size} OFFSET #{offset}")
        break if samples.empty?

        values = samples.map do |row|
          ticker_escaped = ActiveRecord::Base.connection.quote(row['ticker'])
          price = row['price']
          sampled_at = ActiveRecord::Base.connection.quote(row['sampled_at'])
          sample_minute = ActiveRecord::Base.connection.quote(row['sample_minute'])
          source = row['source'] ? ActiveRecord::Base.connection.quote(row['source']) : 'NULL'
          "(#{ticker_escaped}, #{price}, #{sampled_at}, #{sample_minute}, #{source}, NOW(), NOW())"
        end

        ActiveRecord::Base.connection.execute(
          "INSERT INTO price_samples (ticker, price, sampled_at, sample_minute, source, created_at, updated_at) VALUES #{values.join(', ')}"
        )

        total_inserted += samples.length
        offset += batch_size
        print "\r  Progress: #{total_inserted}/#{counts[:price_samples]}"
      end
      puts "\n  ✓ Migrated #{total_inserted} price samples"

      # Reset sequences
      puts "\n🔧 Resetting ID sequences..."
      %w[agents wallets trades positions trade_events price_samples].each do |table|
        ActiveRecord::Base.connection.reset_pk_sequence!(table)
      end
      puts "  ✓ Sequences reset"
    end

    # Verify counts
    puts "\n✅ Verification"
    puts "-" * 60
    pg_counts = {
      agents: Agent.count,
      wallets: Wallet.count,
      trades: Trade.count,
      positions: Position.count,
      trade_events: TradeEvent.count,
      price_samples: ActiveRecord::Base.connection.execute("SELECT COUNT(*) FROM price_samples")[0]['count'].to_i
    }

    all_match = true
    pg_counts.each do |table, pg_count|
      sqlite_count = counts[table]
      match = pg_count == sqlite_count
      all_match = false unless match
      status = match ? "✓" : "✗"
      puts "  #{status} #{table}: SQLite=#{sqlite_count} PostgreSQL=#{pg_count}"
    end

    if all_match
      puts "\n🎉 Migration completed successfully!"
      puts "All record counts match."
    else
      puts "\n⚠️  Migration completed with mismatches."
      puts "Please review the counts above."
    end

    sqlite_db.close
  end
end
