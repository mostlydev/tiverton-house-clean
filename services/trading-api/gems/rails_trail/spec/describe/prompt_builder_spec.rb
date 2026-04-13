require "spec_helper"
require "rails_trail/describe/prompt_builder"

RSpec.describe RailsTrail::Describe::PromptBuilder do
  describe "#build" do
    let(:introspection) do
      {
        service_name: "trading-api",
        routes: [
          { method: "GET", path: "/api/v1/trades", action: "trades#index" },
          { method: "POST", path: "/api/v1/trades", action: "trades#create" },
          { method: "POST", path: "/api/v1/trades/:id/approve", action: "trades#approve" }
        ],
        models: [
          {
            name: "Trade",
            states: ["PROPOSED", "APPROVED", "DENIED", "FILLED"],
            transitions: [
              { event: "approve", from: "PROPOSED", to: "APPROVED" },
              { event: "deny", from: "PROPOSED", to: "DENIED" }
            ],
            manual_moves: [
              { state: "PROPOSED", action: "confirm", description: "Confirm trade" }
            ]
          }
        ]
      }
    end

    it "produces a system prompt and user prompt" do
      builder = described_class.new(introspection)
      result = builder.build
      expect(result[:system]).to include("service manual")
      expect(result[:user]).to include("trading-api")
      expect(result[:user]).to include("/api/v1/trades")
      expect(result[:user]).to include("PROPOSED")
      expect(result[:user]).to include("approve")
    end

    it "includes manual moves in the prompt" do
      builder = described_class.new(introspection)
      result = builder.build
      expect(result[:user]).to include("confirm")
    end
  end
end
