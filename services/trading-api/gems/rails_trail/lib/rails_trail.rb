require "rails_trail/version"
require "rails_trail/configuration"
require "rails_trail/move"
require "rails_trail/navigable"
require "rails_trail/route_map"
require "rails_trail/responses"
require "rails_trail/tool_registration"
require "rails_trail/railtie" if defined?(Rails::Railtie)

module RailsTrail
  class << self
    def configure
      yield(configuration)
    end

    def configuration
      @configuration ||= Configuration.new
    end

    def route_map
      @route_map ||= RouteMap.new
    end

    def reset!
      @configuration = nil
      @route_map = nil
    end
  end
end
