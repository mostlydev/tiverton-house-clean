# frozen_string_literal: true

module News
  # Shared mapping of agent names to Discord user IDs
  # Used across news routing and trade notifications
  module AgentMentions
    AGENT_DISCORD_IDS = {
      'weston' => '1464508643742584904',
      'logan' => '1464522019822375016',
      'gerrard' => '1467937502240182323',
      'dundas' => '1464840602649628764',
      'boulton' => '1469917753157750897',
      'tiverton' => '1464508146579148851'
    }.freeze

    class << self
      # Convert agent name to Discord mention format
      # @param agent_name [String] Agent identifier (weston, logan, etc.)
      # @return [String, nil] Discord mention like "<@123456>" or nil if unknown
      def mention_for(agent_name)
        discord_id = AGENT_DISCORD_IDS[agent_name.to_s.downcase]
        discord_id ? "<@#{discord_id}>" : nil
      end

      # Get Discord ID for an agent
      # @param agent_name [String] Agent identifier
      # @return [String, nil] Discord user ID or nil
      def discord_id_for(agent_name)
        AGENT_DISCORD_IDS[agent_name.to_s.downcase]
      end

      # Get all agent Discord IDs as hash
      # @return [Hash] Map of agent_name => discord_id
      def all
        AGENT_DISCORD_IDS
      end
    end
  end
end
