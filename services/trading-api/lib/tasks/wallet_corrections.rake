# frozen_string_literal: true

namespace :wallets do
  desc "Correct wallet discrepancies caused by position reconciliation bug"
  task correct_discrepancies: :environment do
    puts "=" * 70
    puts "Wallet Discrepancy Correction Tool"
    puts "=" * 70
    puts ""
    puts "This task corrects wallet imbalances caused by the position"
    puts "reconciliation bug that transferred positions without cash adjustments."
    puts ""

    # Step 1: Snapshot current state
    puts "Current Wallet State:"
    puts "-" * 70
    traders = Agent.where(role: 'trader').includes(:wallet)
    system_agent = Agent.find_by(agent_id: 'system')

    total_cash = 0
    total_invested = 0

    traders.each do |agent|
      wallet = agent.wallet
      next unless wallet
      total_cash += wallet.cash
      total_invested += wallet.invested
      puts format("  %-10s cash: $%12.2f  invested: $%12.2f  total: $%12.2f",
                  agent.agent_id, wallet.cash, wallet.invested, wallet.total_value)
    end

    if system_agent&.wallet
      puts format("  %-10s cash: $%12.2f  invested: $%12.2f",
                  'system', system_agent.wallet.cash, system_agent.wallet.invested)
    end

    puts "-" * 70
    puts format("  %-10s cash: $%12.2f  invested: $%12.2f", 'TOTAL', total_cash, total_invested)
    puts ""

    # Step 2: Get Alpaca account for comparison
    puts "Fetching Alpaca account data..."
    broker = Alpaca::BrokerService.new
    begin
      alpaca_account = broker.get_account
      alpaca_equity = alpaca_account[:equity].to_f
      alpaca_cash = alpaca_account[:cash].to_f
      puts format("  Alpaca equity:  $%12.2f", alpaca_equity)
      puts format("  Alpaca cash:    $%12.2f", alpaca_cash)
      puts format("  DB total:       $%12.2f", total_cash + total_invested)
      puts format("  Difference:     $%12.2f", (total_cash + total_invested) - alpaca_equity)
      puts ""
    rescue => e
      puts "  Warning: Could not fetch Alpaca data: #{e.message}"
      alpaca_equity = nil
    end

    # Step 3: Analyze trade history to calculate expected positions
    puts "Analyzing trade history..."
    puts "-" * 70

    corrections = calculate_corrections(traders)

    if corrections.empty?
      puts "No corrections needed!"
      exit 0
    end

    puts ""
    puts "Proposed Corrections:"
    puts "-" * 70
    corrections.each do |agent_id, correction|
      puts format("  %-10s cash adjustment: $%+12.2f  reason: %s",
                  agent_id, correction[:amount], correction[:reason])
    end
    puts ""

    # Confirm before applying
    print "Apply these corrections? [y/N] "
    response = STDIN.gets.chomp
    unless response.downcase == 'y'
      puts "Aborted."
      exit 0
    end

    # Step 4: Apply corrections in a transaction
    puts ""
    puts "Applying corrections..."
    ActiveRecord::Base.transaction do
      corrections.each do |agent_id, correction|
        agent = Agent.find_by!(agent_id: agent_id)
        wallet = agent.wallet

        old_cash = wallet.cash
        new_cash = old_cash + correction[:amount]

        # For system wallet, allow negative values
        if agent_id == 'system'
          wallet.update_column(:cash, new_cash)
        else
          wallet.update!(cash: new_cash)
        end

        puts format("  %-10s: $%.2f -> $%.2f (%+.2f)",
                    agent_id, old_cash, new_cash, correction[:amount])

        # Log the adjustment
        Rails.logger.info(
          "Wallet correction applied: #{agent_id} cash #{old_cash} -> #{new_cash} " \
          "(#{correction[:reason]})"
        )
      end
    end

    puts ""
    puts "Corrections applied successfully!"
    puts ""

    # Step 5: Verify final state
    puts "Final Wallet State:"
    puts "-" * 70
    traders.reload
    total_cash = 0
    total_invested = 0

    traders.each do |agent|
      wallet = agent.wallet.reload
      total_cash += wallet.cash
      total_invested += wallet.invested
      puts format("  %-10s cash: $%12.2f  invested: $%12.2f  total: $%12.2f",
                  agent.agent_id, wallet.cash, wallet.invested, wallet.total_value)
    end

    system_agent&.wallet&.reload
    if system_agent&.wallet
      puts format("  %-10s cash: $%12.2f  invested: $%12.2f",
                  'system', system_agent.wallet.cash, system_agent.wallet.invested)
    end

    puts "-" * 70
    puts format("  %-10s cash: $%12.2f  invested: $%12.2f", 'TOTAL', total_cash, total_invested)

    if alpaca_equity
      puts ""
      puts format("  Alpaca equity:  $%12.2f", alpaca_equity)
      puts format("  DB total:       $%12.2f", total_cash + total_invested)
      puts format("  Difference:     $%12.2f", (total_cash + total_invested) - alpaca_equity)
    end
  end

  desc "Show wallet discrepancies without making changes (dry run)"
  task analyze_discrepancies: :environment do
    puts "=" * 70
    puts "Wallet Discrepancy Analysis (Dry Run)"
    puts "=" * 70
    puts ""

    traders = Agent.where(role: 'trader').includes(:wallet, :positions)
    system_agent = Agent.find_by(agent_id: 'system')

    puts "Current State:"
    puts "-" * 70

    traders.each do |agent|
      wallet = agent.wallet
      next unless wallet
      positions_value = agent.positions.sum(:current_value)

      puts format("  %-10s", agent.agent_id)
      puts format("    cash:     $%12.2f", wallet.cash)
      puts format("    invested: $%12.2f (wallet)", wallet.invested)
      puts format("    invested: $%12.2f (positions)", positions_value)
      if (wallet.invested - positions_value).abs > 0.01
        puts format("    MISMATCH: $%+12.2f", wallet.invested - positions_value)
      end
      puts ""
    end

    # Check for multi-agent positions
    puts "Multi-Agent Positions Check:"
    puts "-" * 70
    Position.where('qty > 0').group(:ticker).having('COUNT(DISTINCT agent_id) > 1').count.each do |ticker, count|
      puts "  #{ticker}: held by #{count} agents"
      Position.includes(:agent).where(ticker: ticker).where('qty > 0').each do |pos|
        puts format("    %-10s: %8.4f shares @ $%.2f", pos.agent.agent_id, pos.qty, pos.avg_entry_price)
      end
    end

    puts ""
    puts "Trade History Summary:"
    puts "-" * 70
    traders.each do |agent|
      buys = Trade.where(agent: agent, side: 'BUY', status: 'FILLED').sum(:filled_value)
      sells = Trade.where(agent: agent, side: 'SELL', status: 'FILLED').sum(:filled_value)
      puts format("  %-10s buys: $%12.2f  sells: $%12.2f  net: $%+12.2f",
                  agent.agent_id, buys, sells, sells - buys)
    end
  end

  # Calculate corrections based on trade history and current state
  def calculate_corrections(traders)
    corrections = {}

    # This is a simplified calculation. For precise corrections,
    # we need to trace through all position transfers and their original cost bases.
    #
    # The plan identified these approximate discrepancies:
    # - Logan: +$9,108 (received free positions)
    # - Gerrard: -$6,667 (lost positions without cash)
    # - Dundas: +$3,056 (received free positions)
    # - Westin: +$660 (received free positions)
    #
    # These will be refined based on actual position transfer history.

    # For now, calculate based on the difference between:
    # 1. Expected wallet state (initial + realized P&L from trades)
    # 2. Current wallet state

    traders.each do |agent|
      wallet = agent.wallet
      next unless wallet

      # Calculate expected cash from trade history
      # Start with initial wallet size (20000 for traders)
      initial_cash = wallet.wallet_size

      # Sum up all buy costs (cash out)
      buy_costs = Trade.where(agent: agent, side: 'BUY', status: 'FILLED').sum(:filled_value)

      # Sum up all sell proceeds (cash in)
      sell_proceeds = Trade.where(agent: agent, side: 'SELL', status: 'FILLED').sum(:filled_value)

      # Expected cash = initial - buys + sells
      expected_cash = initial_cash - buy_costs + sell_proceeds

      # Current position value
      current_invested = wallet.invested

      # The discrepancy is what's unexplained
      actual_total = wallet.cash + current_invested
      expected_total = expected_cash + current_invested

      discrepancy = actual_total - expected_total

      if discrepancy.abs > 1.0 # Only correct if > $1
        corrections[agent.agent_id] = {
          amount: -discrepancy, # Negate to correct
          reason: "Position transfer without cash adjustment"
        }
      end
    end

    # System wallet absorbs the total correction to balance
    if corrections.any?
      total_correction = corrections.values.sum { |c| c[:amount] }
      corrections['system'] = {
        amount: -total_correction,
        reason: "Balancing entry for trader corrections"
      }
    end

    corrections
  end
end
