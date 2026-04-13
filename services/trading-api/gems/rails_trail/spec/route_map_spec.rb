require "spec_helper"
require "rails_trail/route_map"
require "rails_trail/configuration"

RSpec.describe RailsTrail::RouteMap do
  let(:route_map) { described_class.new }

  describe "#register" do
    it "stores a route for a resource action" do
      route_map.register("trades", "approve", method: "POST", path_template: "/api/v1/trades/:id/approve")
      result = route_map.lookup("trades", "approve")
      expect(result[:method]).to eq("POST")
      expect(result[:path_template]).to eq("/api/v1/trades/:id/approve")
    end
  end

  describe "#resolve" do
    before do
      route_map.register("trades", "approve", method: "POST", path_template: "/api/v1/trades/:id/approve")
      route_map.register("trades", "deny", method: "POST", path_template: "/api/v1/trades/:id/deny")
    end

    it "resolves action to method and path with id substituted" do
      trade = double(trade_id: "abc-123")
      trade_class = double(table_name: "trades", trail_definition: double(id_method: :trade_id))

      result = route_map.resolve(trade_class, "approve", trade)
      expect(result[:method]).to eq("POST")
      expect(result[:path]).to eq("/api/v1/trades/abc-123/approve")
    end

    it "returns nil for unknown action" do
      trade_class = double(table_name: "trades", trail_definition: double(id_method: :id))
      result = route_map.resolve(trade_class, "nonexistent", double(id: 1))
      expect(result).to be_nil
    end
  end

  describe "#resource_name_for" do
    it "derives resource name from model table name" do
      expect(route_map.resource_name_for(double(table_name: "trades"))).to eq("trades")
    end
  end
end
