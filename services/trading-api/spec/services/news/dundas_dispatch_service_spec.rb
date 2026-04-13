# frozen_string_literal: true

require 'rails_helper'

RSpec.describe News::DundasDispatchService do
  before do
    allow(DiscordService).to receive(:post_to_trading_floor).and_return(true)
    allow(NotificationDedupeService).to receive(:allow?).and_return(true)
  end

  let(:dispatch) do
    NewsDispatch.create!(
      batch_type: 'news',
      status: 'pending',
      confirmation_token: 'NEWS-123',
      message: 'Test message'
    )
  end

  it 'skips posting and confirms when no agent routing in analysis' do
    described_class.new(dispatch).call

    expect(dispatch.reload.status).to eq('confirmed')
    expect(dispatch.confirmed_at).to be_present
    expect(dispatch.response).to include('Skipped')
  end

  it 'posts to Discord and confirms when analysis includes agent routing' do
    dispatch.update!(metadata: {
      'analysis' => {
        'article-1' => {
          'success' => true,
          'route_to' => ['westin'],
          'auto_post' => true
        }
      }
    })

    described_class.new(dispatch).call

    expect(dispatch.reload.status).to eq('confirmed')
    expect(DiscordService).to have_received(:post_to_trading_floor)
  end

  it 'skips posting when analysis has routing but auto_post is false' do
    dispatch.update!(metadata: {
      'analysis' => {
        'article-1' => {
          'success' => true,
          'route_to' => ['westin'],
          'auto_post' => false
        }
      }
    })

    described_class.new(dispatch).call

    expect(dispatch.reload.status).to eq('confirmed')
    expect(dispatch.response).to include('Skipped')
    expect(DiscordService).not_to have_received(:post_to_trading_floor)
  end

  it 'dedupes repeated payloads before posting to Discord' do
    allow(NotificationDedupeService).to receive(:allow?).and_return(false)
    dispatch.update!(metadata: {
      'analysis' => {
        'article-1' => {
          'success' => true,
          'route_to' => ['westin'],
          'auto_post' => true
        }
      }
    })

    described_class.new(dispatch).call

    expect(dispatch.reload.status).to eq('confirmed')
    expect(dispatch.response).to include('deduped')
    expect(DiscordService).not_to have_received(:post_to_trading_floor)
  end
end
