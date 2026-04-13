# frozen_string_literal: true

require 'rails_helper'

RSpec.describe TraderContextPrimeJob do
  describe '#perform' do
    it 'runs the trader context prime service with the requested params' do
      service = instance_double(TraderContextPrimeService, call: { dividend_snapshots_written: 1 })
      allow(TraderContextPrimeService).to receive(:new)
        .with(days: 15, tickers: %w[CVX JNJ])
        .and_return(service)

      described_class.new.perform(days: 15, tickers: %w[CVX JNJ])

      expect(service).to have_received(:call)
    end
  end
end
