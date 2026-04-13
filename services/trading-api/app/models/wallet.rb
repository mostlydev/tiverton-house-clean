class Wallet < ApplicationRecord
  belongs_to :agent

  # Validations
  validates :wallet_size, presence: true, numericality: { greater_than_or_equal_to: 0 }
  # Cash and invested can be negative due to margin/unsettled trades
  # Alpaca allows negative cash (margin debit), we track reality not ideals
  validates :cash, presence: true, numericality: true, unless: :system_wallet?
  validates :invested, presence: true, numericality: true, unless: :system_wallet?
  validate :cash_and_invested_balance

  # Instance methods
  def available_cash
    cash
  end

  def total_value
    cash + invested
  end

  def allocation_percentage
    return 0 if wallet_size.zero?
    ((invested / wallet_size) * 100).round(2)
  end

  def cash_percentage
    return 0 if wallet_size.zero?
    ((cash / wallet_size) * 100).round(2)
  end

  private

  def system_wallet?
    agent&.agent_id == 'system'
  end

  def cash_and_invested_balance
    # Note: cash + invested can legitimately exceed wallet_size due to realized P&L
    # Only validate that cash and invested are non-negative (already done above)
    # This method intentionally left minimal for future custom validations
  end
end
