# frozen_string_literal: true

# Double-entry rows for each ledger transaction.
# Amount sign: positive = debit, negative = credit
class LedgerEntry < ApplicationRecord
  belongs_to :ledger_transaction
  belongs_to :agent, optional: true
  belongs_to :reconciliation_provenance, optional: true

  validates :entry_seq, presence: true
  validates :account_code, presence: true
  validates :amount, presence: true
  validates :asset, presence: true

  # Account code format: 'agent:{agent_id}:{asset}' or system accounts
  # Examples:
  #   'agent:dundas:cash' - Dundas's cash account
  #   'agent:dundas:AAPL' - Dundas's AAPL position
  #   'alpaca_cash_control' - System cash control
  #   'cash_suspense' - Unallocated cash drift

  scope :for_agent, ->(agent_id) { where(agent_id: agent_id) }
  scope :for_asset, ->(asset) { where(asset: asset) }
  scope :debits, -> { where('amount > 0') }
  scope :credits, -> { where('amount < 0') }
end
