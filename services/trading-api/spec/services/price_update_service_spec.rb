require 'rails_helper'
require 'set'

RSpec.describe PriceUpdateService, type: :service do
  let(:agent) { create(:agent, :westin) }
  let!(:position) do
    create(
      :position,
      agent: agent,
      ticker: 'AAPL',
      qty: 10,
      avg_entry_price: 100.0,
      stop_loss: 95.0,
      current_value: 1000.0
    )
  end

  let(:broker) { instance_double(Alpaca::BrokerService) }

  before do
    allow(MarketHours).to receive(:market_data_active?).and_return(true)
    allow(Alpaca::BrokerService).to receive(:new).and_return(broker)
    allow(broker).to receive(:get_positions).and_return([
      { ticker: 'AAPL', current_price: 94.0 }
    ])
    allow(broker).to receive(:get_asset_symbols).with(asset_class: 'us_equity').and_return(Set['AAPL', 'QQQ', 'SPY', 'TSLA'])
    allow(broker).to receive(:get_latest_bar) do |ticker:, **|
      case ticker
      when 'SPY'
        { success: true, open: 500.0, high: 501.0, low: 499.0, close: 500.5, volume: 1_000_000, trade_count: 10_000, vwap: 500.2 }
      when 'QQQ'
        { success: true, open: 430.0, high: 431.0, low: 429.5, close: 430.5, volume: 800_000, trade_count: 8_000, vwap: 430.2 }
      else
        { success: false, error: 'No bar data' }
      end
    end
    allow(broker).to receive(:get_quote).and_return({ success: true, price: 100.0, last: 100.0 })
    allow(StopLossExecutionJob).to receive(:perform_later)
    allow(AppConfig).to receive(:stop_loss_alert_interval_minutes).and_return(3)
  end

  it 'publishes stop-loss alert when price crosses below stop' do
    described_class.new.call

    expect(StopLossExecutionJob).to have_received(:perform_later).with(position.id, 94.0)
    position.reload
    expect(position.stop_loss_triggered_at).to be_present
    expect(position.stop_loss_last_alert_at).to be_present
    expect(position.stop_loss_alert_count).to eq(1)
  end

  it 'does not alert again before reminder interval has elapsed' do
    position.update!(
      stop_loss_triggered_at: 5.minutes.ago,
      stop_loss_last_alert_at: 2.minutes.ago,
      stop_loss_alert_count: 1
    )

    described_class.new.call

    expect(StopLossExecutionJob).not_to have_received(:perform_later)

    position.reload
    expect(position.stop_loss_alert_count).to eq(1)
  end

  it 'triggers for short positions when price rises above stop' do
    short_position = create(
      :position,
      agent: agent,
      ticker: 'TSLA',
      qty: -5,
      avg_entry_price: 100.0,
      stop_loss: 105.0,
      current_value: -500.0
    )
    allow(broker).to receive(:get_positions).and_return([
      { ticker: 'TSLA', current_price: 106.0 }
    ])

    described_class.new.call

    expect(StopLossExecutionJob).to have_received(:perform_later).with(short_position.id, 106.0)
  end

  it 'records benchmark samples with bar fields for SPY and QQQ' do
    described_class.new.call

    spy = PriceSample.find_by!(ticker: 'SPY')
    qqq = PriceSample.find_by!(ticker: 'QQQ')

    aggregate_failures do
      expect(spy.price.to_f).to eq(500.5)
      expect(spy.close_price.to_f).to eq(500.5)
      expect(spy.volume.to_f).to eq(1_000_000.0)
      expect(spy.trade_count).to eq(10_000)
      expect(spy.asset_class).to eq('us_equity')

      expect(qqq.price.to_f).to eq(430.5)
      expect(qqq.close_price.to_f).to eq(430.5)
      expect(qqq.vwap.to_f).to eq(430.2)
      expect(qqq.asset_class).to eq('us_equity')
    end
  end
end
