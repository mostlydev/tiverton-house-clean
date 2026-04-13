#!/usr/bin/env ruby
# frozen_string_literal: true

# Clean up news files on disk - only keep HIGH impact articles
# Uses NewsDispatch.metadata to determine which articles to keep

require_relative '../config/environment'

NEWS_ROOT = StoragePaths.news_root

def cleanup_news_files
  puts "Building impact map from NewsDispatch records..."
  
  # Build article_id -> impact mapping from all dispatches
  article_impact = {}
  NewsDispatch.where.not(metadata: nil).find_each do |dispatch|
    analysis = dispatch.metadata['analysis'] || dispatch.metadata[:analysis] || {}
    analysis.each do |article_id, data|
      next unless data.is_a?(Hash)
      impact = (data['impact'] || data[:impact]).to_s.upcase
      article_impact[article_id.to_i] = impact if impact.present?
    end
  end
  
  puts "Found impact data for #{article_impact.size} articles"
  
  high_count = article_impact.count { |_, v| v == 'HIGH' }
  low_count = article_impact.count { |_, v| v == 'LOW' }
  medium_count = article_impact.count { |_, v| v == 'MEDIUM' }
  
  puts "HIGH: #{high_count}, MEDIUM: #{medium_count}, LOW: #{low_count}"
  
  # Find all article files
  deleted = 0
  kept = 0
  errors = []
  
  NEWS_ROOT.glob('2026-*/*.md').each do |file|
    # Extract article ID from filename (format: HHMMSS-external_id.md)
    filename = file.basename.to_s
    next unless filename =~ /-\d+\.md$/
    
    external_id = filename.match(/-(\d+)\.md$/)&.[](1)
    next unless external_id
    
    # Find article in database
    article = NewsArticle.find_by(external_id: external_id)
    
    if article.nil?
      puts "Warning: No database record for #{filename}"
      next
    end
    
    impact = article_impact[article.id]
    
    if impact.nil?
      puts "Warning: No impact data for article #{article.id} (#{filename})"
      next
    end
    
    if impact == 'HIGH'
      kept += 1
    else
      begin
        file.delete
        deleted += 1
        puts "Deleted: #{file.relative_path_from(NEWS_ROOT)} (#{impact})"
      rescue => e
        errors << "#{file}: #{e.message}"
      end
    end
  end
  
  puts "\n=== Cleanup Complete ==="
  puts "Kept (HIGH): #{kept}"
  puts "Deleted (LOW/MEDIUM): #{deleted}"
  puts "Errors: #{errors.size}"
  errors.each { |e| puts "  #{e}" }
  
  # Update latest.md
  puts "\nRegenerating latest.md..."
  high_articles = NewsArticle.where(id: article_impact.select { |_, v| v == 'HIGH' }.keys).recent_first
  writer = News::FileWriter.new
  writer.write_latest_summary(high_articles)
  puts "Done!"
end

cleanup_news_files
