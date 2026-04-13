# frozen_string_literal: true

module Dashboard
  class AgentNotesService
    def self.for_agent_ticker(agent_id, ticker)
      new(agent_id, ticker).content
    end

    def initialize(agent_id, ticker)
      @agent_id = agent_id.to_s.downcase
      @ticker = ticker.to_s.upcase
    end

    def content
      return { error: "Invalid agent" } unless valid_agent?
      return { error: "Invalid ticker" } unless valid_ticker?

      note_path = StoragePaths.note_file_path(@agent_id, @ticker)

      unless note_path.exist?
        return { content: "No note found for #{@ticker} under #{@agent_id}.", ticker: @ticker, agent_id: @agent_id }
      end

      { content: note_path.read, ticker: @ticker, agent_id: @agent_id }
    rescue StandardError => e
      { error: e.message }
    end

    private

    def valid_agent?
      @agent_id.match?(/\A[a-z]+\z/)
    end

    def valid_ticker?
      @ticker.match?(/\A[A-Z]{1,5}\z/)
    end
  end
end
