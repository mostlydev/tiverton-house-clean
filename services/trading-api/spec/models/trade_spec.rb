require 'rails_helper'

RSpec.describe Trade, type: :model do
  include ActiveJob::TestHelper
  include ExternalServicesMock

  around do |example|
    DatabaseCleaner.strategy = :truncation
    DatabaseCleaner.cleaning do
      example.run
    end
  ensure
    DatabaseCleaner.strategy = :transaction
  end

  before do
    mock_all_external_services!
  end

  it 'enqueues auto-execution after approval' do
    agent = create(:agent, :logan)
    trade = create(:trade, :proposed, agent: agent, confirmed_at: Time.current)

    expect { trade.approve! }.to have_enqueued_job(TradeExecutionJob).with(trade.id)
  end

  it 'requires confirmation before approval' do
    agent = create(:agent, :logan)
    trade = create(:trade, :proposed, agent: agent, confirmed_at: nil)

    expect(trade.may_approve?).to be(false)
    expect { trade.approve! }.to raise_error(AASM::InvalidTransition)
  end

  it 'publishes outbox notification when a trade is passed' do
    agent = create(:agent, :logan)
    trade = create(:trade, :proposed, agent: agent)
    allow(OutboxPublisherService).to receive(:trade_passed!).and_return(true)

    trade.pass!

    expect(OutboxPublisherService).to have_received(:trade_passed!).with(trade)
  end
end
