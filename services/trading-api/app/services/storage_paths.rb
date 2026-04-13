# frozen_string_literal: true

require "pathname"

module StoragePaths
  module_function

  def repo_root
    Rails.root.join("..", "..")
  end

  def shared_root
    Pathname.new(ENV.fetch("DESK_SHARED_ROOT", repo_root.join("storage", "shared").to_s))
  end

  def news_root
    shared_root.join("news")
  end

  def research_root
    shared_root.join("research", "tickers")
  end

  def private_root
    root = ENV["DESK_PRIVATE_ROOT"].to_s.strip
    return repo_root.join("storage", "private") if root.empty?

    Pathname.new(root)
  end

  def agent_private_root(agent_id)
    private_root.join(agent_key(agent_id))
  end

  def agent_memory_root(agent_id)
    agent_private_root(agent_id).join("memory")
  end

  def agent_notes_root(agent_id)
    agent_private_root(agent_id).join("notes")
  end

  def note_file_path(agent_id, ticker)
    agent_notes_root(agent_id).join("#{ticker.to_s.upcase}.md")
  end

  def research_file_path(ticker)
    research_root.join("#{ticker.to_s.upcase}.md")
  end

  def research_news_path(ticker)
    research_root.join("#{ticker.to_s.upcase}-news.md")
  end

  def agent_key(agent_id)
    agent_id.to_s.downcase
  end
end
