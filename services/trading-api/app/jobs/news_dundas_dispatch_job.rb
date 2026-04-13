# frozen_string_literal: true

class NewsDundasDispatchJob < ApplicationJob
  queue_as :default

  retry_on StandardError, wait: 5.seconds, attempts: 3

  def perform(article_ids, batch_type: 'news', analysis: nil, message: nil, metadata: nil)
    articles = NewsArticle.includes(:news_symbols).where(id: article_ids).recent_first
    return if articles.empty?

    # Skip if these articles were already dispatched recently (within last 2 hours)
        already_dispatched = NewsDispatch
      .where('created_at > ?', 2.hours.ago)
      .where(status: ['confirmed', 'pending'])
      .pluck(:article_ids)
      .flatten
      .uniq
    
    new_articles = articles.reject { |a| already_dispatched.include?(a.id) }
    
    if new_articles.empty?
      Rails.logger.info("[NewsDispatch] All #{articles.size} articles already dispatched recently, skipping")
      return
    end
    
    if new_articles.size < articles.size
      Rails.logger.info("[NewsDispatch] Filtered #{articles.size - new_articles.size} already-dispatched articles, processing #{new_articles.size} new")
    end
    
    articles = new_articles
    
    # Filter to only HIGH impact or routed articles
    important_articles = filter_important_articles(articles, analysis)
    
    if important_articles.empty?
      Rails.logger.info("[NewsDispatch] No HIGH impact or routed articles, skipping dispatch")
      return
    end
    
    if important_articles.size < articles.size
      Rails.logger.info("[NewsDispatch] Filtered to #{important_articles.size} important articles (from #{articles.size})")
    end
    
    articles = important_articles
    confirmation_token = generate_token
    batch = News::BatchFormatter.new(articles, analysis: analysis).call

    message ||= batch

    dispatch = NewsDispatch.create!(
      batch_type: batch_type,
      status: 'pending',
      confirmation_token: confirmation_token,
      message: message,
      article_ids: articles.map(&:id),
      metadata: metadata || {}
    )

    News::DundasDispatchService.new(dispatch).call
  end

  private

  def generate_token
    "%06d" % SecureRandom.random_number(1_000_000)
  end
  
  def filter_important_articles(articles, analysis)
    return [] unless analysis.is_a?(Hash)

    articles.select do |article|
      data = analysis[article.id.to_s] || analysis[article.id] || {}
      next false unless data['success'] || data[:success]

      impact = (data['impact'] || data[:impact]).to_s.upcase

      auto_post = data['auto_post']
      auto_post = data[:auto_post] if auto_post.nil?
      route_to = Array(data['route_to'] || data[:route_to])

      # HIGH impact: always include if routed
      # MEDIUM impact: include if routed to specific agents (held positions/watchlist)
      next false unless auto_post == true && route_to.any?
      impact == 'HIGH' || impact == 'MEDIUM'
    end
  end
end
