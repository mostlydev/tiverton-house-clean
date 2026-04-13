# frozen_string_literal: true

require "rails_helper"

RSpec.describe Api::V1::SystemController, type: :controller do
  describe "GET #status" do
    let!(:agent) { create(:agent, agent_id: "weston", name: "Weston") }

    before do
      allow(LedgerMigration).to receive(:read_from_ledger?).and_return(false)
      allow(LedgerMigration).to receive(:status).and_return(
        write_guard_enabled: false,
        read_source: "legacy",
        write_mode: "legacy",
        mode: "legacy"
      )

      agent.wallet.update!(wallet_size: 25_000.0, cash: 25_000.0, invested: 0.0)

      BrokerAccountSnapshot.create!(
        broker: "alpaca",
        cash: 37_476.97,
        buying_power: 74_953.94,
        equity: 98_489.05,
        portfolio_value: 98_489.05,
        fetched_at: Time.current,
        raw_account: {}
      )
    end

    it "includes broker context alongside internal wallet totals" do
      get :status, format: :json

      expect(response).to have_http_status(:ok)

      json = JSON.parse(response.body)

      expect(json["broker_account"]).to include(
        "source" => "broker_snapshot",
        "cash" => 37_476.97,
        "equity" => 98_489.05
      )

      expect(json["wallets"]).to include(
        "source" => "broker_snapshot",
        "internal_source" => "legacy_positions",
        "total_capital" => 25_000.0,
        "total_cash" => 37_476.97,
        "internal_total_cash" => 25_000.0,
        "total_equity" => 98_489.05,
        "internal_total_equity" => 25_000.0
      )
    end

    it "returns unauthorized without a bearer token" do
      request.headers.delete("Authorization")

      get :status, format: :json

      expect(response).to have_http_status(:unauthorized)
    end

    it "returns not found on the public host" do
      request.host = "www.tivertonhouse.com"

      get :status, format: :json

      expect(response).to have_http_status(:not_found)
    end
  end
end
