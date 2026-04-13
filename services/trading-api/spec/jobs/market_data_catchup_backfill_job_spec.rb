# frozen_string_literal: true

require 'rails_helper'

RSpec.describe MarketDataCatchupBackfillJob do
  describe '#perform' do
    it 'runs a short automatic market-data backfill' do
      service = instance_double(MarketDataBackfillService, call: { total_bars: 0 })
      allow(MarketDataBackfillService).to receive(:new)
        .with(days: described_class::CATCHUP_DAYS)
        .and_return(service)

      described_class.new.perform

      expect(service).to have_received(:call)
    end
  end
end
