# frozen_string_literal: true

# Individual discrepancies found during reconciliation.
class ReconciliationDiff < ApplicationRecord
  belongs_to :reconciliation_run
  belongs_to :ledger_adjustment, optional: true

  validates :entity_type, presence: true
  validates :severity, presence: true
  validates :diff_type, presence: true

  ENTITY_TYPES = %w[order fill position cash wallet].freeze
  SEVERITIES = %w[GREEN YELLOW RED].freeze
  DIFF_TYPES = %w[missing mismatch unexpected].freeze
  RESOLUTION_STATUSES = %w[open resolved ignored].freeze

  enum :severity, {
    green: 'GREEN',
    yellow: 'YELLOW',
    red: 'RED'
  }, prefix: true

  enum :resolution_status, {
    open: 'open',
    resolved: 'resolved',
    ignored: 'ignored'
  }, prefix: true

  scope :critical, -> { where(severity: 'RED') }
  scope :warnings, -> { where(severity: 'YELLOW') }
  scope :unresolved, -> { where(resolution_status: 'open') }

  def resolve!(action:, adjustment: nil)
    update!(
      resolution_status: 'resolved',
      resolution_action: action,
      ledger_adjustment: adjustment
    )
  end
end
