# frozen_string_literal: true

# Scheduled job to clean up old news articles
# - Database: Remove LOW/MEDIUM articles older than 14 days
# - Disk: Keep only HIGH impact + last 24h
class NewsCleanupJob < ApplicationJob
  queue_as :default

  def perform
    Rails.logger.info("[NewsCleanup] Starting cleanup...")
    
    # Run database cleanup
    run_database_cleanup
    
    # Run disk cleanup  
    run_disk_cleanup
    
    Rails.logger.info("[NewsCleanup] Complete")
  end
  
  private
  
  def run_database_cleanup
    cutoff_days = 14
    retention_hours = 24
    
    retention_cutoff = retention_hours.hours.ago
    old_cutoff = cutoff_days.days.ago
    
    # Build impact map
    article_impact = build_impact_map
    
    # Find deletable articles
    to_delete = []
    NewsArticle.where('created_at < ?', old_cutoff).find_each do |article|
      next if article.created_at > retention_cutoff
      
      impact = article_impact[article.id]
      if impact.nil? || impact == 'LOW' || impact == 'MEDIUM'
        to_delete << article.id
      end
    end
    
    return if to_delete.empty?
    
    deleted = 0
    to_delete.each_slice(1000) do |batch|
      NewsArticle.where(id: batch).destroy_all
      deleted += batch.size
    end
    
    Rails.logger.info("[NewsCleanup] Database: Deleted #{deleted} old LOW/MEDIUM articles")
  rescue => e
    Rails.logger.error("[NewsCleanup] Database cleanup failed: #{e.message}")
  end
  
  def run_disk_cleanup
    require 'fileutils'
    
    news_root = StoragePaths.news_root
    retention_cutoff = 24.hours.ago
    
    article_impact = build_impact_map
    deleted = 0
    kept = 0
    
    news_root.glob('2026-*/*.md').each do |file|
      filename = file.basename.to_s
      next unless filename =~ /-(\d+)\.md$/
      
      external_id = filename.match(/-(\d+)\.md$/)[1]
      article = NewsArticle.find_by(external_id: external_id)
      next if article.nil?
      
      # Keep if within 24h
      if article.created_at > retention_cutoff
        kept += 1
        next
      end
      
      # Keep if HIGH impact
      impact = article_impact[article.id]
      if impact == 'HIGH'
        kept += 1
        next
      end
      
      # Delete LOW/MEDIUM older than 24h
      file.delete
      deleted += 1
    end
    
    Rails.logger.info("[NewsCleanup] Disk: Deleted #{deleted} files, kept #{kept}")
  rescue => e
    Rails.logger.error("[NewsCleanup] Disk cleanup failed: #{e.message}")
  end
  
  def build_impact_map
    impact_map = {}
    NewsDispatch.where.not(metadata: nil).find_each do |dispatch|
      analysis = dispatch.metadata['analysis'] || dispatch.metadata[:analysis] || {}
      analysis.each do |article_id, data|
        next unless data.is_a?(Hash)
        impact = (data['impact'] || data[:impact]).to_s.upcase
        impact_map[article_id.to_i] = impact if impact.present?
      end
    end
    impact_map
  end
end
