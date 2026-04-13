# frozen_string_literal: true

ENV['RAILS_ENV'] ||= 'test'
require File.expand_path('../config/environment', __dir__)

# Prevent database truncation if the environment is production
abort('The Rails environment is running in production mode!') if Rails.env.production?

# CRITICAL SAFETY CHECK: Ensure we're connected to the test database
# The development database is used for production - never run tests against it!
db_name = ActiveRecord::Base.connection_db_config.database
unless db_name.include?('test')
  abort(<<~MSG)
    SAFETY ABORT: Tests are attempting to connect to '#{db_name}'!

    Tests MUST run against the test database (trading_test).
    Check that .env.test exists and sets DATABASE_URL correctly.

    Expected: trading_test
    Got: #{db_name}
  MSG
end

require 'rspec/rails'
require 'webmock/rspec'

# Requires supporting ruby files with custom matchers and macros, etc, in
# spec/support/ and its subdirectories.
Dir[Rails.root.join('spec/support/**/*.rb')].each { |f| require f }

# Checks for pending migrations and applies them before tests are run.
begin
  ActiveRecord::Migration.maintain_test_schema!
rescue ActiveRecord::PendingMigrationError => e
  abort e.to_s.strip
end

RSpec.configure do |config|
  # Include FactoryBot methods
  config.include FactoryBot::Syntax::Methods

  # Use transactional fixtures
  config.use_transactional_fixtures = true

  # Infer spec type from file location
  config.infer_spec_type_from_file_location!

  # Filter lines from Rails gems in backtraces
  config.filter_rails_from_backtrace!

  # Database cleaner configuration
  config.before(:suite) do
    DatabaseCleaner.clean_with(:truncation)
  end

  config.before(:each) do
    DatabaseCleaner.strategy = :transaction
  end

  config.before(:each) do
    DatabaseCleaner.start
  end

  config.before(:each, type: :controller) do
    next unless controller.is_a?(ApplicationController)

    allow(AppConfig).to receive(:trading_api_internal_token).and_return("internal-token")
    allow(AppConfig).to receive(:trading_api_agent_tokens).and_return({})
    allow(AppConfig).to receive(:public_web_hosts).and_return(["www.tivertonhouse.com"])
    request.headers["Authorization"] ||= "Bearer internal-token"
  end

  config.before(:each) do
    ActiveJob::Base.queue_adapter = :test
    allow(LedgerMigration).to receive(:write_guard_enabled?).and_return(false)
    allow(LedgerMigration).to receive(:ledger_only_writes?).and_return(false)
    allow(LedgerMigration).to receive(:block_legacy_write?).and_return(false)
    allow(LedgerMigration).to receive(:read_from_ledger?).and_return(false)
    allow(LedgerMigration).to receive(:read_source).and_return('legacy')
    allow(LedgerMigration).to receive(:write_mode).and_return('dual')
  end

  config.after(:each) do
    DatabaseCleaner.clean
  end
end
