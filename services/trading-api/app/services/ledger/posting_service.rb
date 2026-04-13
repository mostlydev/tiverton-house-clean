# frozen_string_literal: true

module Ledger
  # Service for creating balanced ledger entries.
  # Enforces double-entry at both application and database levels.
  class PostingService
    BALANCE_TOLERANCE = 0.00001

    class UnbalancedPostingError < StandardError; end
    class InvalidEntryError < StandardError; end

    attr_reader :transaction, :entries, :errors

    # Create a new posting with entries
    # entries: Array of hashes with { account_code:, amount:, asset:, agent_id: (optional) }
    def initialize(source_type:, source_id:, agent: nil, asset: nil, booked_at: Time.current, description: nil, bootstrap_adjusted: false, reconciliation_provenance: nil)
      @source_type = source_type
      @source_id = source_id
      @agent = agent
      @asset = asset
      @booked_at = booked_at
      @description = description
      @bootstrap_adjusted = bootstrap_adjusted
      @reconciliation_provenance = reconciliation_provenance
      @transaction = nil
      @entries = []
      @errors = []
    end

    # Add an entry to the posting
    # amount: positive = debit, negative = credit
    def add_entry(account_code:, amount:, asset:, agent: nil)
      @entries << {
        account_code: account_code,
        amount: amount.to_f,
        asset: asset,
        agent: agent || @agent
      }
      self
    end

    # Post the entries (validates balance before saving)
    def post!
      validate_entries!
      validate_balance!

      ActiveRecord::Base.transaction do
        create_transaction!
        create_entries!
      end

      @transaction
    end

    # Post without raising (returns true/false)
    def post
      post!
      true
    rescue StandardError => e
      @errors << e.message
      false
    end

    private

    def validate_entries!
      raise InvalidEntryError, 'Must have at least 2 entries for double-entry' if @entries.size < 2

      @entries.each_with_index do |entry, idx|
        raise InvalidEntryError, "Entry #{idx}: account_code is required" if entry[:account_code].blank?
        raise InvalidEntryError, "Entry #{idx}: amount is required" if entry[:amount].nil?
        raise InvalidEntryError, "Entry #{idx}: asset is required" if entry[:asset].blank?
      end
    end

    def validate_balance!
      sum = @entries.sum { |e| e[:amount] }

      if sum.abs > BALANCE_TOLERANCE
        raise UnbalancedPostingError,
              "Entries do not balance: sum = #{sum.round(8)} (expected 0)"
      end
    end

    def create_transaction!
      @transaction = LedgerTransaction.create!(
        ledger_txn_id: generate_txn_id,
        source_type: @source_type,
        source_id: @source_id,
        agent: resolve_agent(@agent),
        asset: @asset,
        booked_at: @booked_at,
        description: @description,
        bootstrap_adjusted: @bootstrap_adjusted,
        reconciliation_provenance: @reconciliation_provenance
      )
    end

    def create_entries!
      @entries.each_with_index do |entry, idx|
        LedgerEntry.create!(
          ledger_transaction: @transaction,
          entry_seq: idx + 1,
          account_code: entry[:account_code],
          amount: entry[:amount],
          asset: entry[:asset],
          agent: resolve_agent(entry[:agent]),
          bootstrap_adjusted: @bootstrap_adjusted,
          reconciliation_provenance: @reconciliation_provenance
        )
      end
    end

    def resolve_agent(agent_or_id)
      return nil if agent_or_id.blank?
      return agent_or_id if agent_or_id.is_a?(Agent)

      Agent.find_by(agent_id: agent_or_id.to_s)
    end

    def generate_txn_id
      timestamp = @booked_at.strftime('%Y%m%d%H%M%S%L')
      random = SecureRandom.hex(4)
      "TXN-#{timestamp}-#{random}"
    end
  end
end
