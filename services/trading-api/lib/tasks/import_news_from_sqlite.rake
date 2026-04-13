# frozen_string_literal: true

namespace :db do
  desc "Import news articles from SQLite index.db into Postgres"
  task import_news_from_sqlite: :environment do
    require 'sqlite3'
    require 'json'

    index_path = ENV['NEWS_INDEX_PATH'] || File.expand_path('<legacy-shared-root>/news/index.db')
    news_root = StoragePaths.news_root.to_s
    limit = ENV['LIMIT']&.to_i
    reset = ENV['RESET_NEWS'] == 'true'
    confirm = ENV['CONFIRM'] == 'true'

    puts "=" * 60
    puts "SQLite News Import"
    puts "=" * 60
    puts "Source: #{index_path}"
    puts "News root: #{news_root}"
    puts "Target: #{ActiveRecord::Base.connection_db_config.database}"
    puts ""

    unless File.exist?(index_path)
      puts "❌ SQLite index not found at: #{index_path}"
      exit 1
    end

    if reset
      unless confirm
        print "⚠️  This will DELETE all existing news records. Continue? [y/N] "
        response = STDIN.gets&.chomp
        unless response&.downcase == 'y'
          puts "Aborted."
          exit 0
        end
      end

      puts "\n🗑️  Clearing existing news data..."
      NewsDispatch.delete_all
      NewsNotification.delete_all
      NewsSummary.delete_all
      NewsSymbol.delete_all
      NewsArticle.delete_all
    end

    sqlite_db = SQLite3::Database.new(index_path)
    sqlite_db.results_as_hash = true

    total = sqlite_db.execute("SELECT COUNT(*) FROM articles")[0][0]
    puts "SQLite articles: #{total}"

    query = "SELECT * FROM articles ORDER BY created_at DESC"
    query += " LIMIT #{limit}" if limit && limit > 0

    imported = 0
    skipped = 0

    sqlite_db.execute(query) do |row|
      external_id = row['id'].to_s
      if external_id.empty? || NewsArticle.exists?(external_id: external_id)
        skipped += 1
        next
      end

      file_path = resolve_file_path(row['file_path'], news_root)
      content = extract_content(file_path)
      summary = content.length > 300 ? "#{content[0, 297]}..." : content

      article = NewsArticle.create!(
        external_id: external_id,
        headline: row['headline'],
        source: row['source'],
        content: content,
        summary: summary,
        url: nil,
        published_at: parse_time(row['created_at']),
        fetched_at: parse_time(row['fetched_at']),
        file_path: file_path,
        raw_json: { import_source: 'sqlite', file_path: file_path }
      )

      symbols = parse_symbols(row['symbols'])
      if symbols.empty?
        symbols = sqlite_db.execute("SELECT symbol FROM article_symbols WHERE article_id = ?", external_id)
                           .map { |sym| sym['symbol'] }
      end

      symbols.uniq.each do |symbol|
        next if symbol.blank?
        article.news_symbols.create!(symbol: symbol)
      end

      imported += 1
      print "\r  Imported: #{imported} (skipped #{skipped})"
    end
    puts ""

    sqlite_db.close

    if imported.positive?
      News::LatestSummaryService.new.call
      puts "✅ Imported #{imported} articles (skipped #{skipped})."
    else
      puts "⚠️  No new articles imported (skipped #{skipped})."
    end
  end

  def parse_time(value)
    return nil if value.nil?
    Time.zone.parse(value.to_s)
  rescue ArgumentError, TypeError
    nil
  end

  def parse_symbols(value)
    return [] if value.nil?
    parsed = JSON.parse(value.to_s)
    return parsed.map(&:to_s) if parsed.is_a?(Array)
    []
  rescue JSON::ParserError
    []
  end

  def resolve_file_path(value, news_root)
    return nil if value.nil?
    path = value.to_s
    return path if path.start_with?('/')
    File.expand_path(File.join(news_root, path))
  end

  def extract_content(path)
    return '' if path.nil? || !File.exist?(path)
    raw = File.read(path)
    return '' if raw.nil?

    body = raw
    if body.start_with?('---')
      parts = body.split("---", 3)
      body = parts[2] if parts.length >= 3
    end

    lines = body.to_s.lines
    lines.shift if lines.first&.start_with?('# ')
    lines.shift if lines.first&.start_with?('**Source:**')

    lines.join.strip
  rescue StandardError
    ''
  end
end
