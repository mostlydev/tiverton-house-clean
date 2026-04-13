require "rails_helper"
require "json"
require "rails_trail/describe/claw_descriptor_generator"

RSpec.describe "claw_describe generation" do
  let(:output_path) { Rails.root.join("tmp", "test.claw-describe.json").to_s }

  before do
    @original_output_path = RailsTrail.configuration.descriptor_output_path
    RailsTrail.configuration.descriptor_output_path = output_path
  end

  after do
    FileUtils.rm_f(output_path)
    RailsTrail.configuration.descriptor_output_path = @original_output_path
  end

  it "produces deterministic output" do
    RailsTrail::Describe::ClawDescriptorGenerator.new.generate
    first = File.read(output_path)

    RailsTrail::Describe::ClawDescriptorGenerator.new.generate
    second = File.read(output_path)

    expect(first).to eq(second)
  end

  it "produces a valid v2 descriptor with the expected tool set" do
    RailsTrail::Describe::ClawDescriptorGenerator.new.generate
    data = JSON.parse(File.read(output_path))

    expect(data["version"]).to eq(2)
    expect(data["auth"]).to include("type" => "bearer", "env" => "TRADING_API_TOKEN")

    tool_names = data["tools"].map { |tool| tool["name"] }
    expect(tool_names).to match_array(
      %w[
        add_to_watchlist
        approve_trade
        cancel_trade
        confirm_trade
        deny_trade
        get_desk_risk_context
        get_market_context
        get_momentum_context
        get_news_latest
        get_pending_trades
        get_positions
        get_quote
        get_ticker_news
        get_trade
        get_watchlist
        list_trades
        pass_trade
        propose_trade
        remove_from_watchlist
      ]
    )
  end

  it "uses body_key wrapping for propose_trade without exposing agent_id" do
    RailsTrail::Describe::ClawDescriptorGenerator.new.generate
    data = JSON.parse(File.read(output_path))
    propose = data["tools"].find { |tool| tool["name"] == "propose_trade" }

    expect(propose["http"]).to include("method" => "POST", "body_key" => "trade", "body" => "json")
    expect(propose["inputSchema"]["properties"]).to include("ticker", "side")
    expect(propose["inputSchema"]["properties"]).not_to include("agent_id")
  end

  it "uses claw_id for context tools and trade_id for get_trade" do
    RailsTrail::Describe::ClawDescriptorGenerator.new.generate
    data = JSON.parse(File.read(output_path))
    market = data["tools"].find { |tool| tool["name"] == "get_market_context" }
    trade = data["tools"].find { |tool| tool["name"] == "get_trade" }

    expect(market["http"]["path"]).to eq("/api/v1/market_context/{claw_id}")
    expect(market["inputSchema"]).to eq("type" => "object")
    expect(trade["http"]["path"]).to eq("/api/v1/trades/{trade_id}")
    expect(trade["inputSchema"]["required"]).to eq(["trade_id"])
  end
end
