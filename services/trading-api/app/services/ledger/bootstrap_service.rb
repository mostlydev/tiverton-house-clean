# frozen_string_literal: true

module Ledger
  # Creates opening balance ledger entries and position lots from current
  # positions and wallets, tied to a reconciliation provenance record.
  #
  # This is a one-time bootstrap operation for migrating to the ledger system.
  # All entries are marked with bootstrap_adjusted=true.
  class BootstrapService
    # Known run IDs for Feb 4 bootstrap
    FEB_4_RUN_IDS = [
      'feb4-2026-full-reconcile-bootstrap',
      'feb-4-2026-emergency-reconcile'
    ].freeze

    Result = Struct.new(:success, :positions_created, :wallets_posted, :errors, keyword_init: true)

    attr_reader :provenance, :booked_at, :errors

    def initialize(provenance: nil, booked_at: nil)
      @provenance = provenance || find_or_create_provenance
      @booked_at = booked_at || @provenance&.completed_at || Time.current
      @errors = []
    end

    # Run the full bootstrap process
    def bootstrap!
      Rails.logger.info("[BootstrapService] Starting bootstrap at #{booked_at.iso8601}")

      position_results = bootstrap_positions
      wallet_results = bootstrap_wallets

      Result.new(
        success: errors.empty?,
        positions_created: position_results[:created],
        wallets_posted: wallet_results[:posted],
        errors: errors
      )
    end

    # Bootstrap position lots from current positions
    def bootstrap_positions
      stats = { created: 0, skipped: 0 }

      Position.includes(:agent).where('qty > 0 OR qty < 0').find_each do |position|
        next if position.qty.zero?

        # Skip if lot already exists for this position
        existing_lot = PositionLot.find_by(
          agent: position.agent,
          ticker: position.ticker,
          bootstrap_adjusted: true,
          reconciliation_provenance: provenance
        )

        if existing_lot
          stats[:skipped] += 1
          next
        end

        create_bootstrap_lot(position)
        stats[:created] += 1

      rescue StandardError => e
        @errors << "Position #{position.ticker}/#{position.agent&.agent_id}: #{e.message}"
        Rails.logger.error("[BootstrapService] Error bootstrapping position: #{e.message}")
      end

      Rails.logger.info("[BootstrapService] Positions: #{stats[:created]} lots created, #{stats[:skipped]} skipped")
      stats
    end

    # Bootstrap ledger entries for wallet cash balances
    def bootstrap_wallets
      stats = { posted: 0, skipped: 0 }

      Wallet.includes(:agent).find_each do |wallet|
        next if wallet.cash.zero?

        # Skip if already posted
        existing = LedgerTransaction.find_by(
          source_type: 'bootstrap_wallet',
          source_id: wallet.id,
          bootstrap_adjusted: true
        )

        if existing
          stats[:skipped] += 1
          next
        end

        post_wallet_opening_balance(wallet)
        stats[:posted] += 1

      rescue StandardError => e
        @errors << "Wallet #{wallet.agent&.agent_id}: #{e.message}"
        Rails.logger.error("[BootstrapService] Error bootstrapping wallet: #{e.message}")
      end

      Rails.logger.info("[BootstrapService] Wallets: #{stats[:posted]} posted, #{stats[:skipped]} skipped")
      stats
    end

    private

    def find_or_create_provenance
      # Look for any existing Feb 4 bootstrap provenance
      existing = ReconciliationProvenance.where(run_id: FEB_4_RUN_IDS).first
      existing ||= ReconciliationProvenance.where(assignment_strategy: 'bootstrap').first
      return existing if existing

      # Create from artifact if it exists
      artifact_path = Rails.root.join('..', '<legacy-shared-root>', 'reports', 'full-reconcile-2026-02-04.json')
      run_id = FEB_4_RUN_IDS.first

      if File.exist?(artifact_path)
        ReconciliationProvenance.create_from_artifact!(
          artifact_path.to_s,
          run_id: run_id,
          operator: 'tiverton',
          notes: 'Feb 4 2026 emergency reconciliation bootstrap'
        )
      else
        # Create minimal provenance record
        ReconciliationProvenance.create!(
          run_id: run_id,
          runner_script: 'ledger/bootstrap_service.rb',
          runner_version: '1.0',
          invocation_params: { source: 'migration' },
          assignment_strategy: 'bootstrap',
          operator: 'system',
          started_at: Time.current,
          completed_at: Time.current,
          status: 'completed',
          notes: 'Ledger migration bootstrap'
        )
      end
    end

    def create_bootstrap_lot(position)
      # Calculate cost basis from position data or use current price
      cost_basis = position.cost_basis || (position.current_price || 0) * position.qty.abs

      PositionLot.create!(
        agent: position.agent,
        ticker: position.ticker,
        qty: position.qty,
        cost_basis_per_share: (cost_basis / position.qty.abs),
        total_cost_basis: cost_basis,
        opened_at: booked_at,
        open_source_type: 'bootstrap',
        open_source_id: position.id,
        bootstrap_adjusted: true,
        reconciliation_provenance: provenance
      )

      Rails.logger.debug("[BootstrapService] Created lot for #{position.agent&.agent_id}/#{position.ticker}: #{position.qty}")
    end

    def post_wallet_opening_balance(wallet)
      agent_id = wallet.agent&.agent_id || 'system'

      posting = Ledger::PostingService.new(
        source_type: 'bootstrap_wallet',
        source_id: wallet.id,
        agent: agent_id,
        asset: 'USD',
        booked_at: booked_at,
        description: "Opening cash balance for #{agent_id}",
        bootstrap_adjusted: true,
        reconciliation_provenance: provenance
      )

      # Double-entry: Debit agent cash, Credit opening balance equity
      cash_account = "agent:#{agent_id}:cash"
      equity_account = "opening_balance:#{agent_id}"

      posting.add_entry(account_code: cash_account, amount: wallet.cash, asset: 'USD')
      posting.add_entry(account_code: equity_account, amount: -wallet.cash, asset: 'USD')

      posting.post!

      Rails.logger.debug("[BootstrapService] Posted wallet balance for #{agent_id}: $#{wallet.cash}")
    end
  end
end
