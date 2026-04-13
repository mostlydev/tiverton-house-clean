# frozen_string_literal: true

require "rails_helper"

RSpec.describe Wallets::BrokerFundingSyncService, type: :service do
  let!(:weston) { create_agent("weston", "Weston", role: "trader", style: "momentum") }
  let!(:logan) { create_agent("logan", "Logan", role: "trader", style: "value") }
  let!(:dundas) { create_agent("dundas", "Dundas", role: "trader", style: "event") }
  let!(:tiverton) { create_agent("tiverton", "Tiverton", role: "infrastructure", style: "risk") }
  let!(:sentinel) { create_agent("sentinel", "Sentinel", role: "infrastructure", style: "executor") }
  let!(:snapshot) do
    BrokerAccountSnapshot.create!(
      broker: "alpaca",
      cash: 50_000.0,
      buying_power: 100_000.0,
      equity: 50_000.0,
      portfolio_value: 50_000.0,
      fetched_at: Time.current,
      raw_account: {}
    )
  end

  before do
    allow(AppConfig).to receive(:wallet_broker_sync_enabled?).and_return(true)
    allow(AppConfig).to receive(:funded_trader_ids).and_return(%w[weston logan])
  end

  it "allocates broker cash evenly across funded traders when the desk is flat" do
    result = described_class.new(snapshot: snapshot).call

    expect(result[:success]).to be true
    expect(result[:applied]).to be true
    expect(result[:allocations]).to eq("weston" => 25_000.0, "logan" => 25_000.0)

    expect(weston.wallet.reload.wallet_size.to_f).to eq(25_000.0)
    expect(weston.wallet.cash.to_f).to eq(25_000.0)
    expect(logan.wallet.reload.wallet_size.to_f).to eq(25_000.0)
    expect(logan.wallet.cash.to_f).to eq(25_000.0)

    [dundas, tiverton, sentinel].each do |agent|
      expect(agent.wallet.reload.wallet_size.to_f).to eq(0.0)
      expect(agent.wallet.cash.to_f).to eq(0.0)
      expect(agent.wallet.invested.to_f).to eq(0.0)
    end
  end

  it "skips the sync when balances are not flat" do
    weston.wallet.update!(cash: 19_900.0, invested: 100.0)

    result = described_class.new(snapshot: snapshot).call

    expect(result[:success]).to be true
    expect(result[:skipped]).to be true
    expect(result[:reason]).to eq("desk is not flat")
    expect(weston.wallet.reload.wallet_size.to_f).to eq(20_000.0)
    expect(logan.wallet.reload.wallet_size.to_f).to eq(20_000.0)
  end

  it "skips the sync when the broker snapshot is not flat" do
    snapshot.update!(cash: 37_476.97, equity: 98_491.86, portfolio_value: 98_491.86)

    result = described_class.new(snapshot: snapshot).call

    expect(result[:success]).to be true
    expect(result[:skipped]).to be true
    expect(result[:reason]).to eq("broker account is not flat")
    expect(result[:book_state][:flat]).to be true
    expect(result[:broker_state][:broker_non_cash_value]).to eq(61_014.89)
    expect(weston.wallet.reload.wallet_size.to_f).to eq(20_000.0)
    expect(logan.wallet.reload.wallet_size.to_f).to eq(20_000.0)
  end

  def create_agent(agent_id, name, role:, style:)
    create(:agent, agent_id: agent_id, name: name, role: role, style: style, status: "active").tap do |agent|
      agent.wallet.update!(wallet_size: 20_000.0, cash: 20_000.0, invested: 0.0)
    end
  end
end
