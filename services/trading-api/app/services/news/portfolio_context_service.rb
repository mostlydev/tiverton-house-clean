# frozen_string_literal: true

module News
  class PortfolioContextService
    def call
      {
        agents: agent_strategies,
        positions: positions_by_agent,
        watchlists: watchlists_by_agent
      }
    end

    private

    def agent_strategies
      Agent.where(role: 'trader').pluck(:agent_id, :name, :style).each_with_object({}) do |(agent_id, name, style), hash|
        description = [name, style.presence].compact.join(' - ')
        hash[agent_id] = description.presence || agent_id
      end
    end

    def positions_by_agent
      positions = Position.includes(:agent).where('qty != 0')
      positions.each_with_object(Hash.new { |h, k| h[k] = [] }) do |position, hash|
        hash[position.agent.agent_id] << "#{position.ticker} (#{position.qty.to_f} shares)"
      end
    end

    def watchlists_by_agent
      Watchlist.includes(:agent).each_with_object(Hash.new { |h, k| h[k] = [] }) do |entry, hash|
        hash[entry.agent.agent_id] << entry.ticker
      end
    end
  end
end
