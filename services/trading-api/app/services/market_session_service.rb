# frozen_string_literal: true

class MarketSessionService
  TIME_ZONE = "America/New_York"

  PRE_MARKET_START = AppConfig.market_pre_open_minutes
  MARKET_OPEN = AppConfig.market_open_minutes
  MARKET_CLOSE = AppConfig.market_close_minutes
  AFTER_HOURS_END = AppConfig.market_after_hours_end_minutes

  def self.current(at: Time.current)
    new(at)
  end

  def initialize(at = Time.current)
    @time = at.in_time_zone(TIME_ZONE)
  end

  def session
    return :closed if weekend?

    current_minutes = minutes_since_midnight(@time)

    if current_minutes < PRE_MARKET_START
      :closed
    elsif current_minutes < MARKET_OPEN
      :pre
    elsif current_minutes < MARKET_CLOSE
      :regular
    elsif current_minutes < AFTER_HOURS_END
      :after
    else
      :closed
    end
  end

  def regular?
    session == :regular
  end

  def extended?
    session == :pre || session == :after
  end

  def closed?
    session == :closed
  end

  def next_regular_open_at
    next_open_at(minutes: MARKET_OPEN)
  end

  def next_extended_open_at
    next_open_at(minutes: PRE_MARKET_START)
  end

  private

  def minutes_since_midnight(time)
    time.hour * 60 + time.min
  end

  def weekend?
    @time.saturday? || @time.sunday?
  end

  def next_open_at(minutes:)
    date = @time.to_date
    current_minutes = minutes_since_midnight(@time)

    if weekend? || current_minutes >= AFTER_HOURS_END
      date = next_weekday(date + 1)
      return time_at(date, minutes)
    end

    if current_minutes < minutes
      return time_at(date, minutes)
    end

    date = next_weekday(date + 1)
    time_at(date, minutes)
  end

  def next_weekday(date)
    while date.saturday? || date.sunday?
      date += 1
    end
    date
  end

  def time_at(date, minutes)
    hour = minutes / 60
    min = minutes % 60
    Time.use_zone(TIME_ZONE) { Time.zone.local(date.year, date.month, date.day, hour, min) }
  end
end
