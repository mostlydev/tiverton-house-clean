# frozen_string_literal: true

# Immutable fill facts from broker executions.
class BrokerFill < ApplicationRecord
  belongs_to :broker_order
  belongs_to :trade
  belongs_to :agent
  belongs_to :reconciliation_provenance, optional: true

  validates :ticker, presence: true
  validates :side, presence: true, inclusion: { in: %w[buy sell] }
  validates :qty, presence: true, numericality: { greater_than: 0 }
  validates :price, presence: true, numericality: { greater_than: 0 }
  validates :executed_at, presence: true
  validates :broker_order, presence: true
  validates :broker_fill_id, uniqueness: true, allow_nil: true

  # Fill confidence levels (ordered by reliability)
  CONFIDENCE_LEVELS = %w[
    broker_verified
    order_derived
    price_interpolated
    reconciliation_assigned
  ].freeze

  enum :fill_id_confidence, {
    broker_verified: "broker_verified",
    order_derived: "order_derived",
    price_interpolated: "price_interpolated",
    reconciliation_assigned: "reconciliation_assigned"
  }, prefix: true

  scope :verified, -> { where(fill_id_confidence: "broker_verified") }
  scope :needs_upgrade, -> { where.not(fill_id_confidence: "broker_verified") }
  scope :bootstrap, -> { where(bootstrap_adjusted: true) }

  def value
    qty * price
  end
end
