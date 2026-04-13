# frozen_string_literal: true

# Mock helpers for external services (Discord, OpenClaw)
#
# These helpers ensure tests don't accidentally call real external services.
# They should be included in rails_helper.rb via RSpec.configure.
#
# Usage:
#   before { mock_all_external_services! }
#
# Or for specific services:
#   before { mock_discord_service! }
#   before { mock_openclaw_service! }
#
module ExternalServicesMock
  # Mock all external services - use this in most tests
  def mock_all_external_services!
    mock_discord_service!
    mock_openclaw_service!
    mock_market_session!
    mock_broker_snapshot!
  end

  # Mock market session as regular hours to prevent market-hours guard failures
  def mock_market_session!
    mock_session = instance_double(MarketSessionService, session: :regular, regular?: true, extended?: false, closed?: false)
    allow(MarketSessionService).to receive(:current).and_return(mock_session)
    allow(Dashboard::MarketStatusService).to receive(:current).and_return(status: "OPEN")
  end

  # Mock broker account snapshot to prevent Alpaca API calls during cash checks
  def mock_broker_snapshot!
    allow(BrokerAccountSnapshotService).to receive(:new).and_return(
      instance_double(BrokerAccountSnapshotService, call: { success: false, error: 'mocked' })
    )
  end

  # Mock Discord service to prevent real HTTP calls
  def mock_discord_service!
    allow(DiscordService).to receive(:post_to_trading_floor).and_return(true)
    allow(DiscordService).to receive(:post_to_infra).and_return(true)
  end

  # Mock Discord with tracking (to verify messages were sent)
  def mock_discord_with_tracking!
    @discord_trading_floor_messages = []
    @discord_infra_messages = []

    allow(DiscordService).to receive(:post_to_trading_floor) do |content:, embed: nil|
      @discord_trading_floor_messages << { content: content, embed: embed }
      true
    end

    allow(DiscordService).to receive(:post_to_infra) do |content:, embed: nil|
      @discord_infra_messages << { content: content, embed: embed }
      true
    end
  end

  # Get messages sent to trading floor (when using mock_discord_with_tracking!)
  def discord_trading_floor_messages
    @discord_trading_floor_messages || []
  end

  # Get messages sent to infra channel (when using mock_discord_with_tracking!)
  def discord_infra_messages
    @discord_infra_messages || []
  end

  # Mock OpenClaw service to prevent real shell commands
  def mock_openclaw_service!
    allow(OpenclawService).to receive(:send_agent_message).and_return("MOCKED")
    allow(OpenclawService).to receive(:send_trading_floor_message).and_return("MOCKED")
  end

  # Mock OpenClaw with tracking
  def mock_openclaw_with_tracking!
    @openclaw_agent_messages = []
    @openclaw_trading_floor_messages = []

    allow(OpenclawService).to receive(:send_agent_message) do |agent:, message:, **_opts|
      @openclaw_agent_messages << { agent: agent, message: message }
      "MOCKED"
    end

    allow(OpenclawService).to receive(:send_trading_floor_message) do |message:, **_opts|
      @openclaw_trading_floor_messages << { message: message }
      "MOCKED"
    end
  end

  # Get agent messages sent via OpenClaw (when using mock_openclaw_with_tracking!)
  def openclaw_agent_messages
    @openclaw_agent_messages || []
  end

  # Get trading floor messages sent via OpenClaw (when using mock_openclaw_with_tracking!)
  def openclaw_trading_floor_messages
    @openclaw_trading_floor_messages || []
  end
end

# Auto-include in RSpec
RSpec.configure do |config|
  config.include ExternalServicesMock

  # Automatically mock Discord for all tests tagged with :mock_discord
  config.before(:each, :mock_discord) do
    mock_discord_service!
  end

  # Automatically mock OpenClaw for all tests tagged with :mock_openclaw
  config.before(:each, :mock_openclaw) do
    mock_openclaw_service!
  end

  # Mock all external services by default for integration tests
  config.before(:each, type: :integration) do
    mock_all_external_services!
  end

  # Mock all external services by default for request specs
  config.before(:each, type: :request) do
    mock_all_external_services!
  end
end
