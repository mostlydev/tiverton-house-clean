# frozen_string_literal: true

class DocsController < ActionController::Base
  include ApplicationHelper
  before_action :disable_session

  def risk_management
    @content = risk_limits_body
    render layout: false
  end

  private

  def disable_session
    request.session_options[:skip] = true
  end

  def risk_limits_body
    raw = File.read(Rails.root.join("policy", "risk-limits.md"))
    raw.sub(/\A# .+\n+/, "")
  end
end
