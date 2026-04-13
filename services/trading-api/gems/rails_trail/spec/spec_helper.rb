require "bundler/setup"
require "active_record"
require "rails_trail"

ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
ActiveRecord::Schema.define do
  suppress_messages do
    create_table :orders, force: true do |t|
      t.string :status, default: "pending"
      t.datetime :delivered_at
    end

    create_table :tickets, force: true do |t|
      t.string :status, default: "open"
      t.datetime :confirmed_at
    end
  end
end

RSpec.configure do |config|
  config.expect_with :rspec do |c|
    c.syntax = :expect
  end
end
