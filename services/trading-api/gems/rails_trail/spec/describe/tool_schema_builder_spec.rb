require "spec_helper"

require "ostruct"

require "rails_trail/describe/tool_schema_builder"
require "active_record"

ActiveRecord::Schema.define do
  suppress_messages do
    create_table :stub_trades, force: true do |t|
      t.string :ticker
      t.string :side
      t.decimal :qty_requested
      t.string :thesis
      t.string :agent_id
    end
  end
end

class StubTrade < ActiveRecord::Base
  self.table_name = "stub_trades"

  validates :ticker, :side, presence: true

  def self.trail_definition
    OpenStruct.new(id_method: :trade_id)
  end
end

RSpec.describe RailsTrail::Describe::ToolSchemaBuilder do
  subject(:builder) { described_class.new }

  describe "#build" do
    it "builds a read tool with normalized path params" do
      tool = builder.build(
        controller: "api/v1/trades",
        action: :show,
        method: "GET",
        path: "/api/v1/trades/:id",
        dsl: { scope: :agent },
        extracted_params: { body_key: nil, properties: [], array_properties: {}, unresolved: false },
        model_class: StubTrade
      )

      expect(tool[:name]).to eq("get_trade")
      expect(tool[:http]).to eq("method" => "GET", "path" => "/api/v1/trades/{trade_id}")
      expect(tool[:inputSchema]["properties"]["trade_id"]).to eq("type" => "string")
      expect(tool[:inputSchema]["required"]).to eq(["trade_id"])
      expect(tool[:annotations]).to eq("readOnly" => true, "scope" => "agent")
    end

    it "builds a write tool with body_key, filtering, and required overrides" do
      tool = builder.build(
        controller: "api/v1/trades",
        action: :create,
        method: "POST",
        path: "/api/v1/trades",
        dsl: {
          scope: :agent,
          name: "propose_trade",
          exclude_params: [:agent_id],
          required: [:ticker, :side]
        },
        extracted_params: {
          body_key: :trade,
          properties: [:agent_id, :ticker, :side, :qty_requested, :thesis],
          array_properties: {},
          unresolved: false
        },
        model_class: StubTrade
      )

      expect(tool[:name]).to eq("propose_trade")
      expect(tool[:http]["body_key"]).to eq("trade")
      expect(tool[:http]["body"]).to eq("json")
      expect(tool[:inputSchema]["properties"].keys).to contain_exactly("ticker", "side", "qty_requested", "thesis")
      expect(tool[:inputSchema]["properties"]["qty_requested"]).to eq("type" => "number")
      expect(tool[:inputSchema]["required"]).to contain_exactly("ticker", "side")
      expect(tool[:annotations]["readOnly"]).to be(false)
    end

    it "supports path overrides for claw-scoped tools" do
      tool = builder.build(
        controller: "api/v1/market_context",
        action: :show,
        method: "GET",
        path: "/api/v1/market_context/:agent_id",
        dsl: { scope: :agent, name: "get_market_context", path: "/api/v1/market_context/{claw_id}" },
        extracted_params: { body_key: nil, properties: [], array_properties: {}, unresolved: false },
        model_class: nil
      )

      expect(tool[:http]["path"]).to eq("/api/v1/market_context/{claw_id}")
      expect(tool[:inputSchema]).to eq("type" => "object")
    end

    it "falls back to a generic object schema when extraction is unresolved" do
      tool = builder.build(
        controller: "api/v1/trades",
        action: :create,
        method: "POST",
        path: "/api/v1/trades",
        dsl: { scope: :agent },
        extracted_params: { body_key: :trade, properties: [], array_properties: {}, unresolved: true },
        model_class: nil
      )

      expect(tool[:inputSchema]).to eq("type" => "object")
    end

    it "emits query params from hash metadata" do
      tool = builder.build(
        controller: "api/v1/news",
        action: :ticker,
        method: "GET",
        path: "/api/v1/news/ticker",
        dsl: {
          scope: :agent,
          name: "get_ticker_news",
          query: {
            ticker: { type: "string", description: "Ticker symbol", required: true },
            days: { type: "integer" },
            limit: { type: "integer" }
          }
        },
        extracted_params: { body_key: nil, properties: [], array_properties: {}, unresolved: false },
        model_class: nil
      )

      expect(tool[:inputSchema]["properties"]["ticker"]).to include("type" => "string", "description" => "Ticker symbol")
      expect(tool[:inputSchema]["properties"]["days"]).to include("type" => "integer")
      expect(tool[:inputSchema]["required"]).to eq(["ticker"])
    end
  end
end
