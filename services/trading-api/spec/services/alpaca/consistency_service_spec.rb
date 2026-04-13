# frozen_string_literal: true

require "rails_helper"

RSpec.describe Alpaca::ConsistencyService, type: :service do
  let(:broker) { instance_double(Alpaca::BrokerService) }

  before do
    allow(Alpaca::BrokerService).to receive(:new).and_return(broker)
    allow(broker).to receive(:get_positions).and_return([])
    allow(broker).to receive(:get_account).and_return(
      success: true,
      cash: 50_000.0,
      equity: 50_000.0
    )
  end

  it "checks cash against legacy wallets in legacy mode" do
    allow(LedgerMigration).to receive(:read_from_ledger?).and_return(false)

    create_wallet_with_cash(25_000.0)
    create_wallet_with_cash(25_000.0)

    result = described_class.new(positions: false, cash: true).call

    expect(result[:cash][:ok]).to be true
    expect(result[:cash][:cash_source]).to eq("legacy_wallets")
    expect(result[:cash][:internal_cash]).to eq(50_000.0)
    expect(result[:cash][:alpaca_cash]).to eq(50_000.0)
  end

  it "checks cash against ledger wallets in ledger mode" do
    allow(LedgerMigration).to receive(:read_from_ledger?).and_return(true)
    allow(Ledger::ProjectionService).to receive(:new).and_return(
      instance_double(
        Ledger::ProjectionService,
        all_wallets: [
          { agent_id: "weston", cash: "25_000.0" },
          { agent_id: "logan", cash: "25_000.0" }
        ]
      )
    )

    result = described_class.new(positions: false, cash: true).call

    expect(result[:cash][:ok]).to be true
    expect(result[:cash][:cash_source]).to eq("ledger_wallets")
    expect(result[:cash][:internal_cash]).to eq(50_000.0)
  end

  def create_wallet_with_cash(amount)
    agent = create(:agent)
    agent.wallet.update!(wallet_size: amount, cash: amount, invested: 0.0)
  end
end
