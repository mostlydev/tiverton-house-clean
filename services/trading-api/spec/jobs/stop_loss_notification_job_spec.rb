# frozen_string_literal: true

require 'rails_helper'

RSpec.describe StopLossNotificationJob, type: :job do
  before do
    allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)
    allow(DiscordService).to receive(:post_to_trading_floor)
    allow(AppConfig).to receive(:discord_notification_dedupe_seconds).and_return(300)
  end

  it 'mentions the owning agent and includes stop-loss details' do
    agent = create(:agent, :logan)
    position = create(:position, agent: agent, ticker: 'AAPL', qty: 25, stop_loss: 140.0, current_value: 3475.0)

    described_class.perform_now(position.id, current_price: 139.0, alert_count: 3)

    expect(DiscordService).to have_received(:post_to_trading_floor).with(
      hash_including(
        content: include('<@1464522019822375016> (logan)')
      )
    )

    expect(DiscordService).to have_received(:post_to_trading_floor).with(
      hash_including(
        content: include('Price $139.0000 <= Stop $140.0000')
      )
    )
  end

  it 'dedupes repeated reminders with the same alert count' do
    agent = create(:agent, :logan)
    position = create(:position, agent: agent, ticker: 'AAPL', qty: 25, stop_loss: 140.0, current_value: 3475.0)

    described_class.perform_now(position.id, current_price: 139.0, alert_count: 2)
    described_class.perform_now(position.id, current_price: 139.0, alert_count: 2)

    expect(DiscordService).to have_received(:post_to_trading_floor).once
  end
end
