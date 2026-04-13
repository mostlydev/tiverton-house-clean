# frozen_string_literal: true

require 'rails_helper'

RSpec.describe MarketSessionService do
  def service_at(year: 2026, month: 2, day: 10, hour: 10, min: 0) # Mon Feb 10 2026
    time = Time.use_zone("America/New_York") { Time.zone.local(year, month, day, hour, min) }
    described_class.new(time)
  end

  describe '#session' do
    it 'returns :closed before pre-market' do
      svc = service_at(hour: 3, min: 0)
      expect(svc.session).to eq(:closed)
    end

    it 'returns :pre during pre-market' do
      svc = service_at(hour: 4, min: 30)
      expect(svc.session).to eq(:pre)
    end

    it 'returns :regular during market hours' do
      svc = service_at(hour: 10, min: 0)
      expect(svc.session).to eq(:regular)
    end

    it 'returns :after during after-hours' do
      svc = service_at(hour: 17, min: 0)
      expect(svc.session).to eq(:after)
    end

    it 'returns :closed after after-hours' do
      svc = service_at(hour: 20, min: 30)
      expect(svc.session).to eq(:closed)
    end

    it 'returns :closed on Saturday' do
      svc = service_at(day: 14, hour: 10) # Sat Feb 14 2026
      expect(svc.session).to eq(:closed)
    end

    it 'returns :closed on Sunday' do
      svc = service_at(day: 15, hour: 10) # Sun Feb 15 2026
      expect(svc.session).to eq(:closed)
    end
  end

  describe '#regular?' do
    it 'true during regular hours' do
      expect(service_at(hour: 12).regular?).to be true
    end

    it 'false during pre-market' do
      expect(service_at(hour: 5).regular?).to be false
    end
  end

  describe '#extended?' do
    it 'true during pre-market' do
      expect(service_at(hour: 5).extended?).to be true
    end

    it 'true during after-hours' do
      expect(service_at(hour: 17).extended?).to be true
    end

    it 'false during regular hours' do
      expect(service_at(hour: 12).extended?).to be false
    end
  end

  describe '#closed?' do
    it 'true on weekends' do
      expect(service_at(day: 14, hour: 12).closed?).to be true
    end

    it 'false during regular hours' do
      expect(service_at(hour: 12).closed?).to be false
    end
  end

  describe '.current' do
    it 'returns a service instance' do
      expect(described_class.current).to be_a(described_class)
    end
  end

  describe '#next_regular_open_at' do
    it 'returns today open time if before market open' do
      svc = service_at(hour: 5, min: 0)
      next_open = svc.next_regular_open_at
      expect(next_open.in_time_zone("America/New_York").hour).to eq(AppConfig.market_open_minutes / 60)
    end

    it 'returns next weekday if after market close' do
      svc = service_at(hour: 21, min: 0) # Tue Feb 10 9 PM
      next_open = svc.next_regular_open_at
      expect(next_open.in_time_zone("America/New_York").wday).to eq(3) # Wednesday
    end

    it 'skips weekends' do
      svc = service_at(day: 14, hour: 12) # Saturday
      next_open = svc.next_regular_open_at
      expect(next_open.in_time_zone("America/New_York").wday).to eq(1) # Monday
    end
  end
end
