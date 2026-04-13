# frozen_string_literal: true

# Groups balanced double-entry postings for one business event.
class LedgerTransaction < ApplicationRecord
  belongs_to :agent, optional: true
  belongs_to :reconciliation_provenance, optional: true

  has_many :ledger_entries, dependent: :destroy
  has_one :ledger_adjustment, dependent: :destroy

  validates :ledger_txn_id, presence: true, uniqueness: true
  validates :source_type, presence: true
  validates :booked_at, presence: true

  SOURCE_TYPES = %w[broker_fill broker_activity adjustment bootstrap].freeze

  scope :from_fills, -> { where(source_type: 'broker_fill') }
  scope :from_activities, -> { where(source_type: 'broker_activity') }
  scope :adjustments, -> { where(source_type: 'adjustment') }
  scope :bootstrap, -> { where(source_type: 'bootstrap') }

  # Verify transaction is balanced (sum of entries = 0)
  def balanced?
    ledger_entries.sum(:amount).abs < 0.00001
  end
end
