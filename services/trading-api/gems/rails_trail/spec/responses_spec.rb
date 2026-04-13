require "spec_helper"
require "active_support/core_ext/object/blank"
require "rails_trail/responses"
require "rails_trail/move"

RSpec.describe RailsTrail::Responses do
  describe ".enrich_payload" do
    let(:moves) { [RailsTrail::Move.new(action: "approve", http_method: "POST", path: "/api/v1/trades/1/approve")] }
    let(:model) { double(next_moves: moves) }

    it "appends next_moves to a hash when trail: model is passed" do
      payload = { trade_id: "abc", status: "PROPOSED" }
      result = described_class.enrich_payload(payload, trail: model)
      expect(result[:next_moves]).to eq([{ action: "approve", method: "POST", path: "/api/v1/trades/1/approve" }])
    end

    it "appends next_moves when payload responds to next_moves" do
      allow(model).to receive(:as_json).and_return({ trade_id: "abc" })
      result = described_class.enrich_payload(model, trail: nil)
      expect(result[:next_moves]).to be_present
    end

    it "does not modify payload when trail: false" do
      payload = { trade_id: "abc" }
      result = described_class.enrich_payload(payload, trail: false)
      expect(result).not_to have_key(:next_moves)
    end

    it "handles array payloads" do
      allow(model).to receive(:as_json).and_return({ trade_id: "abc" })
      payload = [model, model]
      result = described_class.enrich_payload(payload, trail: nil)
      expect(result).to be_an(Array)
      expect(result.first[:next_moves]).to be_present
    end
  end
end
