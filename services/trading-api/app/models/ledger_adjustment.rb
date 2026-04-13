# frozen_string_literal: true

# Controlled correction path for ledger adjustments.
# All adjustments require provenance and evidence.
class LedgerAdjustment < ApplicationRecord
  belongs_to :ledger_transaction, optional: true
  belongs_to :reconciliation_provenance, optional: true

  validates :reason_code, presence: true

  REASON_CODES = %w[
    bootstrap_position
    bootstrap_cash
    corporate_action
    dividend_reinvest
    fee_correction
    manual_override
    reconciliation_fix
    data_migration
  ].freeze

  scope :bootstrap, -> { where(reason_code: %w[bootstrap_position bootstrap_cash]) }
  scope :corrections, -> { where(reason_code: %w[reconciliation_fix manual_override fee_correction]) }
end
