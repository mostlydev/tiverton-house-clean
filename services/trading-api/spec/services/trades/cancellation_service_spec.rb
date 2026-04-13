# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Trades::CancellationService do
  let(:agent) { create(:agent) }

  before do
    mock_all_external_services!
  end

  describe '#call' do
    context 'when trade is PROPOSED' do
      let(:trade) { create(:trade, agent: agent) }

      it 'cancels the trade' do
        result = described_class.new(trade, reason: 'Changed mind').call
        expect(result.success?).to be true
        expect(trade.reload.status).to eq('CANCELLED')
      end

      it 'records the cancellation reason' do
        described_class.new(trade, reason: 'Changed mind').call
        expect(trade.reload.denial_reason).to eq('Changed mind')
      end

      it 'creates a CANCELLED trade event with correct actor' do
        described_class.new(trade, cancelled_by: 'tiverton', reason: 'Not aligned').call
        events = trade.trade_events.where(event_type: 'CANCELLED')
        # log_status_change callback creates one with actor="system",
        # CancellationService creates another with the actual cancelled_by
        expect(events.where(actor: 'tiverton')).to exist
      end
    end

    context 'when trade is APPROVED' do
      let(:trade) { create(:trade, :approved, agent: agent) }

      it 'cancels approved trades' do
        result = described_class.new(trade).call
        expect(result.success?).to be true
        expect(trade.reload.status).to eq('CANCELLED')
      end
    end

    context 'when trade is EXECUTING with alpaca order' do
      let(:trade) do
        create(:trade, :executing, agent: agent, alpaca_order_id: 'order-abc-123')
      end

      it 'cancels the alpaca order and the trade' do
        broker = instance_double(Alpaca::BrokerService)
        allow(Alpaca::BrokerService).to receive(:new).and_return(broker)
        allow(broker).to receive(:cancel_order).and_return({ success: true })

        result = described_class.new(trade).call
        expect(result.success?).to be true
        expect(trade.reload.status).to eq('CANCELLED')
        expect(broker).to have_received(:cancel_order).with(order_id: 'order-abc-123')
      end

      it 'fails when alpaca cancellation fails' do
        broker = instance_double(Alpaca::BrokerService)
        allow(Alpaca::BrokerService).to receive(:new).and_return(broker)
        allow(broker).to receive(:cancel_order).and_return({ success: false, error: 'Order not found' })

        result = described_class.new(trade).call
        expect(result.success?).to be false
        expect(result.error).to include('Order not found')
      end
    end

    context 'when trade is FILLED (terminal state)' do
      let(:trade) { create(:trade, :filled, agent: agent) }

      it 'returns failure' do
        result = described_class.new(trade).call
        expect(result.success?).to be false
        expect(result.error).to include('Cannot cancel')
      end
    end

    context 'defaults' do
      let(:trade) { create(:trade, agent: agent) }

      it 'defaults cancelled_by to system' do
        described_class.new(trade).call
        event = trade.trade_events.find_by(event_type: 'CANCELLED')
        expect(event.actor).to eq('system')
      end
    end
  end
end
