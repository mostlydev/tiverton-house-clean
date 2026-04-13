# Seeds for Trading API
# Based on db-helper.py AGENTS_SEED

puts "Seeding agents and wallets..."

agents_data = [
  { agent_id: 'weston', name: 'Weston', role: 'trader', style: 'momentum' },
  { agent_id: 'logan', name: 'Logan', role: 'trader', style: 'value' },
  { agent_id: 'dundas', name: 'Dundas', role: 'trader', style: 'event' },
  { agent_id: 'gerrard', name: 'Gerrard', role: 'trader', style: 'macro' },
  { agent_id: 'danforth', name: 'Danforth', role: 'trader', style: 'special_situations' },
  { agent_id: 'tiverton', name: 'Tiverton', role: 'infrastructure', style: 'risk' },
  { agent_id: 'sentinel', name: 'Sentinel', role: 'infrastructure', style: 'executor' },
  { agent_id: 'allen', name: 'Allen', role: 'analyst', style: 'research', default_execution_policy: 'immediate' }
]

agents_data.each do |data|
  agent = Agent.find_or_initialize_by(agent_id: data[:agent_id])
  agent.name = data[:name]
  agent.role = data[:role]
  agent.style = data[:style]
  agent.status = 'active'
  agent.default_execution_policy = data[:default_execution_policy] if data[:default_execution_policy]
  agent.save!

  wallet = Wallet.find_or_initialize_by(agent: agent)
  if wallet.new_record?
    wallet.wallet_size = 0
    wallet.cash = 0
    wallet.invested = 0
    wallet.save!
  end

  puts "  ✓ Ensured #{agent.name} (#{agent.agent_id}) - #{agent.role}/#{agent.style}"
end

puts "\nSeeding complete!"
puts "  - #{Agent.count} agents"
puts "  - #{Wallet.count} wallets"
puts "  - Trading agents: #{Agent.traders.count}"
puts "  - Infrastructure agents: #{Agent.infrastructure.count}"
puts "  - Analyst agents: #{Agent.analysts.count}"

snapshot_result = BrokerAccountSnapshotService.new.call
if snapshot_result[:success]
  sync_result = Wallets::BrokerFundingSyncService.new(snapshot: snapshot_result[:snapshot]).call
  if sync_result[:success] && sync_result[:applied]
    puts "  - Wallet funding synced from broker snapshot: #{sync_result[:allocations]}"
  elsif sync_result[:success] && sync_result[:skipped]
    puts "  - Wallet funding sync skipped: #{sync_result[:reason]}"
  else
    puts "  - Wallet funding sync failed: #{sync_result[:error]}"
  end
else
  puts "  - Broker snapshot unavailable during seed: #{snapshot_result[:error]}"
end
