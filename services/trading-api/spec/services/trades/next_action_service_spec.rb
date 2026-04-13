# frozen_string_literal: true

require "rails_helper"

RSpec.describe Trades::NextActionService do
  let(:agent) { create(:agent, :logan) }

  it "returns Tiverton advisory task for newly proposed trades" do
    trade = create(:trade, :proposed, agent: agent, confirmed_at: nil, approved_at: nil)
    next_action = described_class.new(trade).as_json

    expect(next_action[:actor]).to eq("tiverton")
    expect(next_action[:action]).to eq("advise")
    expect(next_action[:message]).to include("Both are needed before execution")
    expect(next_action[:complete]).to be(false)
  end

  it "keeps Tiverton as next actor when trader already confirmed" do
    trade = create(:trade, :proposed, agent: agent, confirmed_at: Time.current, approved_at: nil)
    next_action = described_class.new(trade).as_json

    expect(next_action[:actor]).to eq("tiverton")
    expect(next_action[:action]).to eq("approve")
    expect(next_action[:message]).to include("mechanical compliance check")
  end

  it "returns trader confirmation task when trade is approved but unconfirmed" do
    trade = create(
      :trade,
      agent: agent,
      status: "APPROVED",
      approved_by: "tiverton",
      approved_at: Time.current,
      confirmed_at: nil
    )
    next_action = described_class.new(trade).as_json

    expect(next_action[:actor]).to eq("logan")
    expect(next_action[:action]).to eq("confirm")
    expect(next_action[:message]).to include("POST /api/v1/trades/#{trade.trade_id}/confirm")
  end

  it "returns complete when approval and confirmation are both present" do
    trade = create(:trade, :approved, agent: agent)
    next_action = described_class.new(trade).as_json

    expect(next_action[:actor]).to be_nil
    expect(next_action[:action]).to be_nil
    expect(next_action[:complete]).to be(true)
  end
end
