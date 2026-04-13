# frozen_string_literal: true

class BrokerAccountSnapshotService
  def initialize(broker: 'alpaca')
    @broker = broker
  end

  def call
    broker_client = Alpaca::BrokerService.new
    account = broker_client.get_account

    unless account[:success]
      return { success: false, error: account[:error] || 'account fetch failed' }
    end

    snapshot = BrokerAccountSnapshot.create!(
      broker: @broker,
      cash: account[:cash],
      buying_power: account[:buying_power],
      equity: account[:equity],
      portfolio_value: account[:portfolio_value],
      fetched_at: Time.current,
      raw_account: account
    )

    { success: true, snapshot: snapshot }
  rescue StandardError => e
    { success: false, error: e.message }
  end
end
