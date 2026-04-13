# frozen_string_literal: true

# Lot inventory for position tracking.
# Only long positions supported (qty > 0). Sells close existing lots.
class PositionLot < ApplicationRecord
  belongs_to :agent
  belongs_to :reconciliation_provenance, optional: true

  validates :ticker, presence: true
  validates :qty, presence: true, numericality: { greater_than: 0, message: "must be positive (sells close lots, not create negative ones)" }
  validates :cost_basis_per_share, presence: true, numericality: { greater_than: 0 }
  validates :opened_at, presence: true
  validate :open_lots_cannot_exceed_position, on: :create

  scope :open, -> { where(closed_at: nil) }
  scope :closed, -> { where.not(closed_at: nil) }
  scope :long, -> { where("qty > 0") }
  scope :for_ticker, ->(ticker) { where(ticker: ticker) }
  scope :bootstrap, -> { where(bootstrap_adjusted: true) }

  before_save :calculate_total_cost_basis
  after_create :log_creation_source

  def open?
    closed_at.nil?
  end

  def long?
    qty.positive?
  end

  private

  def calculate_total_cost_basis
    self.total_cost_basis = qty.abs * cost_basis_per_share
  end

  def log_creation_source
    source = caller.find { |c| c.include?('trading-api/app/') }
    Rails.logger.info("[POSITION_LOT_AUDIT] Created: #{agent&.agent_id}/#{ticker} qty=#{qty} source=#{source}")
  end

  # Prevent creating lots that would exceed the agent's net position from fills
  def open_lots_cannot_exceed_position
    return unless agent_id && ticker && qty
    return if bootstrap_adjusted?
    return if closed_at.present?

    # Calculate net position from broker fills
    buys = BrokerFill.where(agent_id: agent_id, ticker: ticker, side: "buy").sum(:qty)
    sells = BrokerFill.where(agent_id: agent_id, ticker: ticker, side: "sell").sum(:qty)
    fill_net = buys - sells

    # Calculate current open lots (excluding self if persisted)
    existing_lots = PositionLot.where(agent_id: agent_id, ticker: ticker, closed_at: nil)
    existing_lots = existing_lots.where.not(id: id) if persisted?
    current_lot_qty = existing_lots.sum(:qty)

    # New total would be current + this lot
    new_total = current_lot_qty + qty

    if new_total > fill_net + 0.0001 # small tolerance for float precision
      errors.add(:qty, "would create #{new_total.round(4)} shares in lots but only #{fill_net.round(4)} shares from fills")
    end
  end
end
