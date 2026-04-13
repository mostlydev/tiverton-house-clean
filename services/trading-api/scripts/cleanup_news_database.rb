#!/usr/bin/env ruby
# frozen_string_literal: true

# Database cleanup: Remove LOW/MEDIUM impact articles older than 14 days
# Keeps HIGH impact indefinitely (for research/historical purposes)
# Keeps last 24h regardless of impact (to avoid re-downloading)

require_relative '../config/environment'

CUTOFF_DAYS = 14
RETENTION_HOURS = 24

def cleanup_database
  puts "=== Database Cleanup: News Articles ==="
  puts "Removing LOW/MEDIUM impact articles older than #{CUTOFF_DAYS} days..."
  puts "(Keeping last #{RETENTION_HOURS}h regardless of impact)"
  
  retention_cutoff = RETENTION_HOURS.hours.ago
  old_cutoff = CUTOFF_DAYS.days.ago
  
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
  
  puts "Impact data available for #{article_impact.size} articles"
  
  # Find deletable articles:
  # - LOW or MEDIUM impact
  # - Older than 14 days
  # - NOT in last 24h
  to_delete = []
  
  NewsArticle.where('created_at < ?', old_cutoff).find_each do |article|
    # Skip if in retention window
    next if article.created_at > retention_cutoff
    
    impact = article_impact[article.id]
    
    # Delete if LOW or MEDIUM (or no impact data - assume LOW)
    if impact.nil? || impact == 'LOW' || impact == 'MEDIUM'
      to_delete << article.id
    end
  end
  
  puts "Found #{to_delete.size} articles to delete"
  
  if to_delete.any?
    batch_size = 1000
    deleted_count = 0
    
    to_delete.each_slice(batch_size) do |batch|
      NewsArticle.where(id: batch).destroy_all
      deleted_count += batch.size
      print "."
    end
    
    puts "\nDeleted #{deleted_count} articles"
  else
    puts "Nothing to delete"
  end
  
  # Summary
  remaining = NewsArticle.count
  high_count = NewsArticle.where(id: article_impact.select { |_, v| v == 'HIGH' }.keys).count
  
  puts "\n=== Summary ==="
  puts "Total articles remaining: #{remaining}"
  puts "HIGH impact: ~#{high_count}"
  puts "Cleanup complete!"
end

cleanup_database
