require_relative "boot"

require "rails"
# Pick the frameworks you want:
require "active_model/railtie"
require "active_job/railtie"
require "active_record/railtie"
require "active_storage/engine"
require "action_controller/railtie"
require "action_mailer/railtie"
require "action_mailbox/engine"
require "action_text/engine"
require "action_view/railtie"
require "action_cable/engine"
# require "rails/test_unit/railtie"

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

module TradingApi
  class Application < Rails::Application
    # Initialize configuration defaults for originally generated Rails version.
    config.load_defaults 7.2

    # Ensure background jobs run through Sidekiq (not inline/async)
    config.active_job.queue_adapter = :sidekiq

    # Please, add to the `ignore` list any other `lib` subdirectories that do
    # not contain `.rb` files, or that should not be reloaded or eager loaded.
    # Common ones are `templates`, `generators`, or `middleware`, for example.
    config.autoload_lib(ignore: %w[assets tasks])

    # Configuration for the application, engines, and railties goes here.
    #
    # These settings can be overridden in specific environments using the files
    # in config/environments, which are processed later.
    #
    config.time_zone = "Eastern Time (US & Canada)"
    # config.eager_load_paths << Rails.root.join("extras")

    # Full stack Rails with Hotwire for dashboard
    # Session middleware for CSRF protection
    config.middleware.use ActionDispatch::Cookies
    config.middleware.use ActionDispatch::Session::CookieStore

    ENV.fetch("PUBLIC_WEB_HOSTS", "www.tivertonhouse.com").split(",").map(&:strip).reject(&:empty?).each do |host|
      config.hosts << host
    end

    ENV.fetch("ALLOWED_HOSTS", "").split(",").map(&:strip).reject(&:empty?).each do |host|
      config.hosts << host
    end
  end
end
