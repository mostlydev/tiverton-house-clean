# frozen_string_literal: true

# Non-order account activities (dividends, fees, transfers, etc.)
class BrokerAccountActivity < ApplicationRecord
  validates :broker_activity_id, presence: true, uniqueness: true
  validates :activity_type, presence: true
  validates :activity_date, presence: true

  # Activity types from Alpaca
  ACTIVITY_TYPES = %w[
    DIV     # Dividend
    DIVROI  # Dividend return of capital
    FEE     # Fee
    INT     # Interest
    JNLC    # Journal cash
    JNLS    # Journal stock
    MA      # Merger/acquisition
    NC      # Name change
    PTC     # Pass-through charge
    REORG   # Reorg
    SC      # Symbol change
    SSO     # Stock spinoff
    SSP     # Stock split
    CFEE    # Crypto fee
    CSR     # Crypto short interest rebate
    CSW     # Crypto sweep
  ].freeze

  scope :dividends, -> { where(activity_type: %w[DIV DIVROI]) }
  scope :fees, -> { where(activity_type: %w[FEE CFEE PTC]) }
  scope :journals, -> { where(activity_type: %w[JNLC JNLS]) }
end
