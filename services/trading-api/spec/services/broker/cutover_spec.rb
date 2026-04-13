# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Broker::Cutover do
  around do |example|
    original = ENV['BROKER_CUTOVER_AT']
    example.run
  ensure
    ENV['BROKER_CUTOVER_AT'] = original
  end

  describe '.configured_at' do
    it 'returns nil when unset' do
      ENV['BROKER_CUTOVER_AT'] = nil

      expect(described_class.configured_at).to be_nil
    end

    it 'parses the configured timestamp' do
      ENV['BROKER_CUTOVER_AT'] = '2026-03-09T00:00:00-04:00'

      expect(described_class.configured_at).to eq(Time.zone.parse('2026-03-09T00:00:00-04:00'))
    end
  end

  describe '.apply' do
    it 'raises older timestamps to the cutover' do
      ENV['BROKER_CUTOVER_AT'] = '2026-03-09T00:00:00-04:00'

      expect(described_class.apply(Time.zone.parse('2026-03-08T23:00:00-04:00')))
        .to eq(Time.zone.parse('2026-03-09T00:00:00-04:00'))
    end

    it 'leaves newer timestamps unchanged' do
      ENV['BROKER_CUTOVER_AT'] = '2026-03-09T00:00:00-04:00'
      ts = Time.zone.parse('2026-03-09T10:00:00-04:00')

      expect(described_class.apply(ts)).to eq(ts)
    end
  end

  describe '.allow?' do
    it 'rejects timestamps before cutover' do
      ENV['BROKER_CUTOVER_AT'] = '2026-03-09T00:00:00-04:00'

      expect(described_class.allow?(Time.zone.parse('2026-03-08T23:59:59-04:00'))).to be(false)
    end

    it 'allows timestamps at or after cutover' do
      ENV['BROKER_CUTOVER_AT'] = '2026-03-09T00:00:00-04:00'

      expect(described_class.allow?(Time.zone.parse('2026-03-09T00:00:00-04:00'))).to be(true)
      expect(described_class.allow?(Time.zone.parse('2026-03-09T09:45:00-04:00'))).to be(true)
    end
  end
end
