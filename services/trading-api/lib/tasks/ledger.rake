# frozen_string_literal: true

namespace :ledger do
  desc 'Bootstrap ledger from current positions and wallets'
  task bootstrap: :environment do
    puts 'Starting ledger bootstrap...'
    puts ''

    service = Ledger::BootstrapService.new
    result = service.bootstrap!

    puts ''
    puts '=== Bootstrap Results ==='
    puts "Positions created: #{result.positions_created}"
    puts "Wallets posted: #{result.wallets_posted}"
    puts "Success: #{result.success}"

    if result.errors.any?
      puts ''
      puts 'Errors:'
      result.errors.each { |e| puts "  - #{e}" }
    end

    puts ''
    puts 'Done.'
  end

  desc 'Show ledger statistics'
  task stats: :environment do
    puts '=== Ledger Statistics ==='
    puts ''
    puts "LedgerTransactions: #{LedgerTransaction.count}"
    puts "  - Bootstrap: #{LedgerTransaction.where(bootstrap_adjusted: true).count}"
    puts "  - Fill-sourced: #{LedgerTransaction.where(source_type: 'BrokerFill').count}"
    puts ''
    puts "LedgerEntries: #{LedgerEntry.count}"
    puts "  - Bootstrap: #{LedgerEntry.where(bootstrap_adjusted: true).count}"
    puts ''
    puts "PositionLots: #{PositionLot.count}"
    puts "  - Open: #{PositionLot.where(closed_at: nil).count}"
    puts "  - Closed: #{PositionLot.where.not(closed_at: nil).count}"
    puts "  - Bootstrap: #{PositionLot.where(bootstrap_adjusted: true).count}"
    puts ''
    puts "BrokerFills: #{BrokerFill.count}"
    puts "  - Verified: #{BrokerFill.where(fill_id_confidence: 'broker_verified').count}"
    puts "  - Order-derived: #{BrokerFill.where(fill_id_confidence: 'order_derived').count}"
    puts "  - Bootstrap: #{BrokerFill.where(bootstrap_adjusted: true).count}"
    puts ''
    puts "BrokerOrders: #{BrokerOrder.count}"
    puts "BrokerAccountActivities: #{BrokerAccountActivity.count}"
    puts ''
    puts "ReconciliationProvenance: #{ReconciliationProvenance.count}"
  end

  desc 'Verify ledger balance (all entries should sum to zero)'
  task verify_balance: :environment do
    puts 'Verifying ledger balance...'
    puts ''

    # Check each transaction is balanced
    unbalanced = []
    LedgerTransaction.find_each do |txn|
      sum = txn.ledger_entries.sum(:amount)
      if sum.abs > 0.00001
        unbalanced << { id: txn.id, ledger_txn_id: txn.ledger_txn_id, sum: sum }
      end
    end

    if unbalanced.any?
      puts "WARNING: Found #{unbalanced.count} unbalanced transactions:"
      unbalanced.each do |txn|
        puts "  - #{txn[:ledger_txn_id]}: sum = #{txn[:sum]}"
      end
    else
      puts 'All transactions are balanced!'
    end

    # Check overall ledger balance
    total_sum = LedgerEntry.sum(:amount)
    puts ''
    puts "Total ledger sum: #{total_sum}"
    puts total_sum.abs < 0.00001 ? 'Ledger is balanced!' : 'WARNING: Ledger is not balanced!'
  end

  desc 'Compare position lots to legacy positions'
  task compare_positions: :environment do
    puts 'Comparing position lots to legacy positions...'
    puts ''

    Position.includes(:agent).where('qty != 0').find_each do |position|
      agent_id = position.agent&.agent_id
      lot_qty = PositionLot
                .joins(:agent)
                .where(agents: { agent_id: agent_id }, ticker: position.ticker, closed_at: nil)
                .sum(:qty)

      diff = (position.qty - lot_qty).abs
      status = diff < 0.0001 ? 'OK' : 'MISMATCH'

      puts "[#{status}] #{agent_id}/#{position.ticker}: legacy=#{position.qty} lots=#{lot_qty}"
    end
  end

  desc 'Compare wallet balances to ledger cash entries'
  task compare_wallets: :environment do
    puts 'Comparing wallet balances to ledger cash entries...'
    puts ''

    Wallet.includes(:agent).find_each do |wallet|
      agent_id = wallet.agent&.agent_id
      cash_account = "agent:#{agent_id}:cash"
      ledger_cash = LedgerEntry.where(account_code: cash_account).sum(:amount)

      diff = (wallet.cash - ledger_cash).abs
      status = diff < 0.01 ? 'OK' : 'MISMATCH'

      puts "[#{status}] #{agent_id}: wallet=$#{wallet.cash.round(2)} ledger=$#{ledger_cash.round(2)}"
    end
  end

  desc 'Run shadow comparison and record results'
  task shadow_compare: :environment do
    puts 'Running shadow comparison...'
    puts ''

    service = Ledger::ShadowComparisonService.new
    result = service.compare!

    puts "Run ID: #{result.summary[:run_id]}"
    puts "Status: #{result.summary[:status]}"
    puts ''
    puts "Position diffs: #{result.summary[:position_diffs_count]}"
    puts "Wallet diffs: #{result.summary[:wallet_diffs_count]}"
    puts ''
    puts "GREEN: #{result.summary[:diffs_green]}"
    puts "YELLOW: #{result.summary[:diffs_yellow]}"
    puts "RED: #{result.summary[:diffs_red]}"
    puts ''

    if result.position_diffs.any?
      puts 'Position Diffs:'
      result.position_diffs.each do |diff|
        puts "  [#{diff.severity}] #{diff.entity_key}: expected=#{diff.expected_state['qty']} actual=#{diff.actual_state['qty']}"
      end
      puts ''
    end

    if result.wallet_diffs.any?
      puts 'Wallet Diffs:'
      result.wallet_diffs.each do |diff|
        puts "  [#{diff.severity}] #{diff.entity_key}: expected=$#{diff.expected_state['cash']&.round(2)} actual=$#{diff.actual_state['cash']&.round(2)}"
      end
      puts ''
    end

    if result.summary[:pause_flag]
      puts 'WARNING: Pause flag is set due to RED diffs!'
    else
      puts 'No RED diffs - system healthy.'
    end
  end

  desc 'Show recent reconciliation runs'
  task recent_runs: :environment do
    puts 'Recent reconciliation runs:'
    puts ''

    runs = ReconciliationRun.order(started_at: :desc).limit(10)

    if runs.empty?
      puts 'No runs found.'
      return
    end

    runs.each do |run|
      duration = run.completed_at ? "#{(run.completed_at - run.started_at).round(1)}s" : 'running'
      puts "[#{run.status}] #{run.run_id}"
      puts "  Started: #{run.started_at.strftime('%Y-%m-%d %H:%M:%S')}"
      puts "  Duration: #{duration}"
      puts "  GREEN: #{run.diffs_green}, YELLOW: #{run.diffs_yellow}, RED: #{run.diffs_red}"
      puts "  #{run.summary}" if run.summary.present?
      puts ''
    end
  end
end
