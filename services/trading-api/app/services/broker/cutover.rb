# frozen_string_literal: true

module Broker
  class Cutover
    class << self
      def configured_at
        raw = ENV['BROKER_CUTOVER_AT'].to_s.strip
        return nil if raw.empty?

        Time.zone.parse(raw)
      rescue ArgumentError, TypeError
        nil
      end

      def configured?
        configured_at.present?
      end

      def apply(time)
        cutover = configured_at
        return time unless cutover
        return cutover if time.blank? || time < cutover

        time
      end

      def allow?(time)
        cutover = configured_at
        return true unless cutover
        return false if time.blank?

        time >= cutover
      end
    end
  end
end
