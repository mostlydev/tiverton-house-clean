# frozen_string_literal: true

require 'rails_helper'

RSpec.describe DiscordNotificationJob, type: :job do
  before do
    allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)
    allow(DiscordService).to receive(:post_to_trading_floor)
    allow(DiscordService).to receive(:post_to_infra)
    allow(AppConfig).to receive(:discord_notification_dedupe_seconds).and_return(300)
  end

  it 'posts a trade notification to trading floor' do
    trade = create(:trade, :approved, :sell, ticker: 'AAPL')

    described_class.perform_now(trade.id, :approved)

    expect(DiscordService).to have_received(:post_to_trading_floor).with(hash_including(content: include('[APPROVED]')))
  end

  it 'dedupes repeated notifications within the window' do
    trade = create(:trade, :approved, :sell, ticker: 'AAPL')

    described_class.perform_now(trade.id, :approved)
    described_class.perform_now(trade.id, :approved)

    expect(DiscordService).to have_received(:post_to_trading_floor).once
  end

  it 'allows different event types to post' do
    trade = create(:trade, :approved, :sell, ticker: 'AAPL')

    described_class.perform_now(trade.id, :approved)
    described_class.perform_now(trade.id, :failed)

    expect(DiscordService).to have_received(:post_to_trading_floor).with(hash_including(content: include('[APPROVED]')))
    expect(DiscordService).to have_received(:post_to_trading_floor).with(hash_including(content: include('[FAILED]')))
  end

  it 'does not ping the proposing trader in PROPOSED notifications' do
    agent = create(:agent, :logan)
    trade = create(:trade, :proposed, agent: agent, ticker: 'CMCSA', side: 'SELL', qty_requested: 67)

    described_class.perform_now(trade.id, :proposed)

    expect(DiscordService).to have_received(:post_to_trading_floor).with(
      hash_including(content: include('Agent: logan'))
    )

    expect(DiscordService).to have_received(:post_to_trading_floor).with(
      hash_including(content: include('Next: <@1464508146579148851> This trade is proposed. Tiverton: give advisory feedback in Discord mentioning the proposing trader by <@DISCORD_ID>, then run the compliance check and approve or deny via the API. Trader: confirm intent via the API when ready. Both are needed before execution.'))
    )

    expect(DiscordService).to have_received(:post_to_trading_floor).with(
      hash_including(content: satisfy { |msg| !msg.include?('<@1464522019822375016>') })
    )
  end

  it 'pings Tiverton (not trader) when CONFIRMED is still awaiting approval' do
    agent = create(:agent, :logan)
    trade = create(:trade, :proposed, agent: agent, ticker: 'CMCSA', side: 'SELL', qty_requested: 67, confirmed_at: Time.current)

    described_class.perform_now(trade.id, :confirmed)

    expect(DiscordService).to have_received(:post_to_trading_floor).with(
      hash_including(content: include('Agent: logan'))
    )

    expect(DiscordService).to have_received(:post_to_trading_floor).with(
      hash_including(content: include('Next: <@1464508146579148851> This trade has been confirmed. Run the mechanical compliance check and approve if hard limits pass, otherwise deny with the specific rule breach.'))
    )

    expect(DiscordService).to have_received(:post_to_trading_floor).with(
      hash_including(content: satisfy { |msg| !msg.include?('<@1464522019822375016>') })
    )
  end

  it 'does not ping Tiverton or trader in CONFIRMED notifications when already approved' do
    agent = create(:agent, :logan)
    trade = create(:trade, :approved, agent: agent, ticker: 'CMCSA', side: 'SELL', qty_requested: 67)

    described_class.perform_now(trade.id, :confirmed)

    expect(DiscordService).to have_received(:post_to_trading_floor).with(
      hash_including(content: include('Agent: logan'))
    )

    expect(DiscordService).to have_received(:post_to_trading_floor).with(
      hash_including(content: include('Status: Approval and confirmation complete; execution is scheduled automatically.'))
    )

    expect(DiscordService).to have_received(:post_to_trading_floor).with(
      hash_including(content: satisfy { |msg| !msg.include?('<@1464522019822375016>') && !msg.include?('<@1464508146579148851>') })
    )
  end

  it 'pings trader for confirmation when APPROVED trade is still unconfirmed' do
    agent = create(:agent, :logan)
    trade = create(
      :trade,
      agent: agent,
      status: 'APPROVED',
      approved_by: 'tiverton',
      approved_at: Time.current,
      confirmed_at: nil,
      ticker: 'CMCSA',
      side: 'SELL',
      qty_requested: 67
    )

    described_class.perform_now(trade.id, :approved)

    expect(DiscordService).to have_received(:post_to_trading_floor).with(
      hash_including(content: include("Next: <@1464522019822375016> (logan) This trade is approved. Confirm it through the trading-api service surface with POST /api/v1/trades/#{trade.trade_id}/confirm if you want to proceed."))
    )
  end

  it 'pings requester and tiverton on FAILED notifications' do
    agent = create(:agent, :logan)
    trade = create(
      :trade,
      agent: agent,
      status: 'FAILED',
      ticker: 'CMCSA',
      side: 'SELL',
      qty_requested: 67,
      execution_error: 'Broker rejected order'
    )

    described_class.perform_now(trade.id, :failed)

    expect(DiscordService).to have_received(:post_to_trading_floor).with(
      hash_including(content: include('[FAILED]'))
    )
    expect(DiscordService).to have_received(:post_to_trading_floor).with(
      hash_including(content: include('Next: <@1464522019822375016> (logan) acknowledge and re-propose or pass. <@1464508146579148851> review execution failure.'))
    )
    expect(DiscordService).to have_received(:post_to_infra).with(
      hash_including(content: include('Requester: <@1464522019822375016> (logan)'))
    )
  end

  it 'renders explicit tiverton mentions with advisory-only instructions in FOLLOW UP task reminders' do
    agent = create(:agent, :logan)
    trade = create(:trade, :proposed, agent: agent, ticker: 'CMCSA', side: 'SELL', qty_requested: 67)

    described_class.perform_now(trade.id, :next_action_nudge)

    expect(DiscordService).to have_received(:post_to_trading_floor).with(
      hash_including(
        content: include('Next: <@1464508146579148851> This trade is proposed. Tiverton: give advisory feedback in Discord mentioning the proposing trader by <@DISCORD_ID>, then run the compliance check and approve or deny via the API. Trader: confirm intent via the API when ready. Both are needed before execution.'),
        allowed_mentions: { parse: [] }
      )
    )
  end

  it 'renders explicit trader mentions without pinging in FOLLOW UP reminders awaiting confirmation' do
    agent = create(:agent, :logan)
    trade = create(
      :trade,
      agent: agent,
      status: 'APPROVED',
      approved_by: 'tiverton',
      approved_at: Time.current,
      confirmed_at: nil,
      ticker: 'CMCSA',
      side: 'SELL',
      qty_requested: 67
    )

    described_class.perform_now(trade.id, :next_action_nudge)

    expect(DiscordService).to have_received(:post_to_trading_floor).with(
      hash_including(
        content: include("Next: <@1464522019822375016> (logan) This trade is approved. Confirm it through the trading-api service surface with POST /api/v1/trades/#{trade.trade_id}/confirm if you want to proceed."),
        allowed_mentions: { parse: [] }
      )
    )
  end

  it 'mentions requester when trade is PASSED' do
    agent = create(:agent, :logan)
    trade = create(:trade, agent: agent, status: 'PASSED', ticker: 'CMCSA', side: 'SELL', qty_requested: 67)

    described_class.perform_now(trade.id, :passed)

    expect(DiscordService).to have_received(:post_to_trading_floor).with(
      hash_including(content: include('[PASSED]'))
    )
    expect(DiscordService).to have_received(:post_to_trading_floor).with(
      hash_including(content: include('Status: <@1464522019822375016> (logan) passed after feedback.'))
    )
  end
end
