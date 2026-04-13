class Position < ApplicationRecord
  belongs_to :agent

  # Validations
  validates :ticker, presence: true
  validates :qty, presence: true, numericality: true
  validates :avg_entry_price, presence: true, numericality: { greater_than: 0 }
  validates :ticker, uniqueness: { scope: :agent_id }
  validates :asset_class, presence: true, inclusion: { in: %w[us_equity us_option crypto crypto_perp] }
  validates :stop_loss, numericality: { greater_than: 0 }, allow_nil: true
  validate :stop_loss_present_for_open_position

  # Callbacks
  after_create :log_creation_source

  # Scopes
  scope :by_agent, ->(agent_id) { where(agent_id: agent_id) }
  scope :open_positions, -> { where('qty != 0') }

  # Instance methods
  def cost_basis
    qty * avg_entry_price
  end

  def unrealized_pnl
    return nil unless current_value
    current_value - cost_basis
  end

  def unrealized_pnl_percentage
    return nil unless current_value
    return 0 if cost_basis.zero?
    ((unrealized_pnl / cost_basis) * 100).round(2)
  end

  def to_s
    "#{agent.agent_id}: #{qty} shares of #{ticker} @ $#{avg_entry_price}"
  end

  private

  def stop_loss_present_for_open_position
    return if qty.to_f == 0
    return if stop_loss.present?

    errors.add(:stop_loss, 'must be present for open positions')
  end

  def log_creation_source
    source = caller.find { |c| c.include?('trading-api/app/') }
    Rails.logger.info("[POSITION_AUDIT] Created: #{agent&.agent_id}/#{ticker} qty=#{qty} source=#{source}")
  end
end
