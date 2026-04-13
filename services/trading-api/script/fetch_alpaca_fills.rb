#!/usr/bin/env ruby
# frozen_string_literal: true

# Fetch all historical fill activities from Alpaca and save to JSON

require 'json'

broker = Alpaca::BrokerService.new

puts "Fetching all FILL activities from Alpaca..."
all_fills = []
page_token = nil
page_count = 0

loop do
  page_count += 1
  puts "  Fetching page #{page_count}..."

  result = broker.get_activities(
    activity_types: ['FILL'],
    page_size: 100,
    page_token: page_token
  )

  unless result[:success]
    puts "  Error: #{result[:error]}"
    break
  end

  activities = result[:activities] || []
  all_fills.concat(activities)
  puts "    Got #{activities.length} fills (total so far: #{all_fills.length})"

  page_token = result[:next_page_token]
  break if page_token.nil? || activities.empty?

  sleep 0.1 # Rate limit courtesy
end

puts ""
puts "Total fills fetched: #{all_fills.length}"

if all_fills.any?
  # Sort chronologically (oldest first)
  all_fills.sort_by! { |f| f[:transaction_time] }

  first = all_fills.first
  last = all_fills.last

  puts "Date range: #{first[:transaction_time]} to #{last[:transaction_time]}"
  puts ""
  puts "Sample (first 10):"
  all_fills.first(10).each do |fill|
    puts "  #{fill[:transaction_time]} | #{fill[:symbol]} | #{fill[:side]} | #{fill[:qty]} @ $#{fill[:price]} | order: #{fill[:order_id]}"
  end

  # Save to file
  output_path = '<operator-home>/alpaca-historical-fills.json'
  File.write(output_path, JSON.pretty_generate({
    fetched_at: Time.now.utc.iso8601,
    total_count: all_fills.length,
    date_range: {
      first: first[:transaction_time],
      last: last[:transaction_time]
    },
    fills: all_fills
  }))

  puts ""
  puts "Saved #{all_fills.length} fill activities to: #{output_path}"
  puts ""
  puts "Summary by ticker:"
  all_fills.group_by { |f| f[:symbol] }.each do |ticker, fills|
    buys = fills.count { |f| f[:side] == 'buy' }
    sells = fills.count { |f| f[:side] == 'sell' }
    puts "  #{ticker}: #{buys} buys, #{sells} sells (#{fills.length} total)"
  end
else
  puts "No fill activities found"
end
