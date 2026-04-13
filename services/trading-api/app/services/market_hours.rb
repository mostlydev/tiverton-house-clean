# frozen_string_literal: true

class MarketHours
  TIME_ZONE = 'America/New_York'

  class << self
    def now
      Time.current.in_time_zone(TIME_ZONE)
    end

    def status(at_time = now)
      return 'CLOSED (weekend)' if weekend?(at_time)

      hour = at_time.hour
      minute = at_time.min

      if hour < 4
        'CLOSED (overnight)'
      elsif hour < 9 || (hour == 9 && minute < 30)
        'PRE-MARKET (opens 9:30 ET)'
      elsif hour < 16
        'OPEN'
      elsif hour < 20
        'AFTER-HOURS'
      else
        'CLOSED'
      end
    end

    def market_data_active?(at_time = now)
      return false if weekend?(at_time)
      hour = at_time.hour
      hour >= 4 && hour < 20
    end

    private

    def weekend?(at_time)
      at_time.saturday? || at_time.sunday?
    end
  end
end
