# frozen_string_literal: true

# Execution metadata for reconciliation passes.
class ReconciliationRun < ApplicationRecord
  has_many :reconciliation_diffs, dependent: :destroy

  validates :run_id, presence: true, uniqueness: true
  validates :scope, presence: true
  validates :started_at, presence: true

  SCOPES = %w[orders fills positions cash full].freeze
  STATUSES = %w[running completed failed paused].freeze

  enum :status, {
    running: 'running',
    completed: 'completed',
    failed: 'failed',
    paused: 'paused'
  }, prefix: true

  scope :recent, -> { order(started_at: :desc) }
  scope :with_red_diffs, -> { where('diffs_red > 0') }
  scope :with_yellow_diffs, -> { where('diffs_yellow > 0') }

  def has_critical_diffs?
    diffs_red.positive?
  end

  def has_warnings?
    diffs_yellow.positive?
  end

  def complete!(summary_text = nil)
    update!(
      status: 'completed',
      completed_at: Time.current,
      summary: summary_text,
      diffs_green: reconciliation_diffs.where(severity: 'GREEN').count,
      diffs_yellow: reconciliation_diffs.where(severity: 'YELLOW').count,
      diffs_red: reconciliation_diffs.where(severity: 'RED').count
    )
  end
end
