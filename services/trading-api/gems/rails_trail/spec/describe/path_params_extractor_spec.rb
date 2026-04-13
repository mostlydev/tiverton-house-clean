require "spec_helper"

require "rails_trail/describe/path_params_extractor"

RSpec.describe RailsTrail::Describe::PathParamsExtractor do
  describe ".extract" do
    it "returns [] for routes with no params" do
      expect(described_class.extract("/api/v1/trades")).to eq([])
    end

    it "extracts single :id" do
      expect(described_class.extract("/api/v1/trades/:id")).to eq([:id])
    end

    it "extracts multiple params" do
      expect(described_class.extract("/api/v1/trades/:trade_id/events/:id")).to eq([:trade_id, :id])
    end

    it "extracts brace params while ignoring claw_id" do
      expect(described_class.extract("/api/v1/market_context/{claw_id}")).to eq([])
      expect(described_class.extract("/api/v1/trades/{trade_id}")).to eq([:trade_id])
    end
  end
end
