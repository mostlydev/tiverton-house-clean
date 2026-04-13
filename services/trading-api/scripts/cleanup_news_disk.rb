#!/usr/bin/env ruby
# frozen_string_literal: true

# Disk cleanup: Keep HIGH impact + last 24h of all articles
# Removes LOW/MEDIUM articles older than 24h from disk

require_relative '../config/environment'

NEWS_ROOT = StoragePaths.news_root
RETENTION_HOURS = 24

def cleanup_disk
  puts "=== Disk Cleanup: News Files ==="
  puts "Keeping HIGH impact + last #{RETENTION_HOURS}h of all articles..."
  
  retention_cutoff = RETENTION_HOURS.hours.ago
  
  # Build article impact map from dispatches
  article_impact = {}
  NewsDispatch.where.not(metadata: nil).find_each do |dispatch|
    analysis = dispatch.metadata['analysis'] || dispatch.metadata[:analysis] || {}
    analysis.each do |article_id, data|
      next unless data.is_a?(Hash)
      impact = (data['impact'] || data[:impact]).to_s.upcase
      article_impact[article_id.to_i] = impact if impact.present?
    end
  end
  
  # Find files to delete
  deleted = 0
  kept = 0
  kept_24h = 0
  
  NEWS_ROOT.glob('2026-*/*.md').each do |file|
    filename = file.basename.to_s
    next unless filename =~ /-(\d+)\.md$/
    
    external_id = filename.match(/-(\d+)\.md$/)[1]
    article = NewsArticle.find_by(external_id: external_id)
    
    if article.nil?
      puts "Warning: No DB record for #{filename}"
      next
    end
    
    # Always keep if within last 24h
    if article.created_at > retention_cutoff
      kept += 1
      kept_24h += 1
      next
    end
    
    # Keep if HIGH impact
    impact = article_impact[article.id]
    if impact == 'HIGH'
      kept += 1
      next
    end
    
    # Delete LOW/MEDIUM older than 24h
    begin
      file.delete
      deleted += 1
    rescue => e
      puts "Error deleting #{file}: #{e.message}"
    end
  end
  
  puts "\n=== Summary ==="
  puts "Kept: #{kept} (including #{kept_24h} from last 24h)"
  puts "Deleted: #{deleted}"
  
  # Regenerate latest.md with remaining articles
  puts "\nRegenerating latest.md..."
  high_articles = NewsArticle.where(id: article_impact.select { |_, v| v == 'HIGH' }.keys).recent_first
  writer = News::FileWriter.new
  writer.write_latest_summary(high_articles)
  puts "Done!"
end

cleanup_disk
