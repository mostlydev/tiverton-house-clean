require "spec_helper"

require "rails_trail/describe/name_deriver"

RSpec.describe RailsTrail::Describe::NameDeriver do
  describe ".derive" do
    it "maps index to list_{resource_plural}" do
      expect(described_class.derive(controller: "api/v1/trades", action: "index")).to eq("list_trades")
    end

    it "maps show to get_{resource_singular}" do
      expect(described_class.derive(controller: "api/v1/positions", action: "show")).to eq("get_position")
    end

    it "maps create to create_{resource_singular}" do
      expect(described_class.derive(controller: "api/v1/trades", action: "create")).to eq("create_trade")
    end

    it "maps update to update_{resource_singular}" do
      expect(described_class.derive(controller: "api/v1/positions", action: "update")).to eq("update_position")
    end

    it "maps destroy to delete_{resource_singular}" do
      expect(described_class.derive(controller: "api/v1/watchlists", action: "destroy")).to eq("delete_watchlist")
    end

    it "uses action verbatim + resource singular for custom actions" do
      expect(described_class.derive(controller: "api/v1/trades", action: "approve")).to eq("approve_trade")
      expect(described_class.derive(controller: "api/v1/trades", action: "confirm")).to eq("confirm_trade")
    end

    it "handles singleton-resource controllers" do
      expect(described_class.derive(controller: "api/v1/desk_risk_context", action: "show")).to eq("get_desk_risk_context")
    end
  end
end
