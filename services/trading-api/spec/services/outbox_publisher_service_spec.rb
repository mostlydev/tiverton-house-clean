require 'rails_helper'

RSpec.describe OutboxPublisherService, type: :service do
  describe '.trade_filled!' do
    let(:trade) { create(:trade, :executing, qty_requested: 10) }
    let(:first_fill_time) { Time.zone.parse('2026-04-03 13:17:05') }

    before do
      trade.update!(
        status: 'FILLED',
        execution_completed_at: first_fill_time,
        qty_filled: 10,
        avg_fill_price: 118.93,
        filled_value: 1189.30
      )
    end

    it 'dedupes repeated publishes for the same fill snapshot' do
      expect do
        2.times { described_class.trade_filled!(trade) }
      end.to change(OutboxEvent.where(event_type: 'trade_filled'), :count).by(1)
    end

    it 'publishes a new event when a corrected trade fills again later' do
      described_class.trade_filled!(trade)
      first_key = OutboxEvent.order(:id).last.sequence_key

      trade.update!(
        status: 'EXECUTING',
        execution_completed_at: nil,
        qty_filled: nil,
        avg_fill_price: nil,
        filled_value: nil
      )

      trade.update!(
        status: 'FILLED',
        execution_completed_at: Time.zone.parse('2026-04-06 09:30:22'),
        qty_filled: 10,
        avg_fill_price: 126.50,
        filled_value: 1265.00
      )

      expect do
        described_class.trade_filled!(trade)
      end.to change(OutboxEvent.where(event_type: 'trade_filled'), :count).by(1)

      keys = OutboxEvent.order(:id).last(2).map(&:sequence_key)
      expect(keys).to include(first_key)
      expect(keys.uniq.size).to eq(2)
    end
  end

  describe '.desk_performance_digest!' do
    it 'dedupes repeated publishes for the same session key' do
      expect do
        2.times { described_class.desk_performance_digest!(session_key: '20260411-08') }
      end.to change(OutboxEvent.where(event_type: 'desk_performance_digest'), :count).by(1)
    end
  end
end
