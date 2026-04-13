require "spec_helper"

require "rails_trail/configuration"

RSpec.describe RailsTrail::Configuration do
  subject(:config) { described_class.new }

  describe "descriptor fields" do
    it "defaults descriptor_output_path to nil" do
      expect(config.descriptor_output_path).to be_nil
    end

    it "accepts descriptor_auth as a hash" do
      config.descriptor_auth = { type: "bearer", env: "TRADING_API_TOKEN" }
      expect(config.descriptor_auth).to eq(type: "bearer", env: "TRADING_API_TOKEN")
    end

    it "accepts descriptor_skill as a relative path string" do
      config.descriptor_skill = "docs/skills/trade.md"
      expect(config.descriptor_skill).to eq("docs/skills/trade.md")
    end

    it "accepts descriptor_description" do
      config.descriptor_description = "Trading API"
      expect(config.descriptor_description).to eq("Trading API")
    end

    it "accepts descriptor_feeds as an array of feed hashes" do
      feeds = [{ name: "market-context", path: "/api/v1/market_context/{claw_id}", ttl: 60 }]
      config.descriptor_feeds = feeds
      expect(config.descriptor_feeds).to eq(feeds)
    end

    it "defaults descriptor_feeds to an empty array" do
      expect(config.descriptor_feeds).to eq([])
    end
  end
end
