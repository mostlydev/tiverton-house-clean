require "digest"

class ApplicationController < ActionController::API
  extend RailsTrail::ToolRegistration
  extend RailsTrail::Responses::ClassMethods
  include RailsTrail::Responses::InstanceMethods
  include RequestSurfaceGuard

  ApiPrincipal = Struct.new(:id, :type, keyword_init: true) do
    def internal?
      type == :internal
    end

    def agent?
      type == :agent
    end

    def coordinator?
      type == :coordinator
    end

    def analyst?
      type == :analyst
    end
  end

  before_action :block_public_web_access!
  before_action :require_api_principal!

  private

  # Deprecated compatibility hook.
  # The API no longer uses network location as an authentication boundary.
  def require_local_request
    true
  end

  def local_request?
    false
  end

  def current_api_principal
    @current_api_principal ||= authenticate_api_principal(bearer_token)
  end

  def require_api_principal!
    return true if current_api_principal.present?

    render json: { error: "Unauthorized" }, status: :unauthorized
    false
  end

  def require_internal_api_principal!
    return false unless require_api_principal!
    return true if current_api_principal&.internal?

    render json: { error: "Forbidden" }, status: :forbidden
    false
  end

  def require_coordinator_or_internal_api_principal!
    return false unless require_api_principal!
    return true if current_api_principal&.internal? || current_api_principal&.coordinator?

    render json: { error: "Forbidden" }, status: :forbidden
    false
  end

  def require_trade_owner_or_internal_api_principal!(trade, allow_coordinator: false)
    return false unless require_api_principal!
    return true if current_api_principal&.internal?
    return true if allow_coordinator && current_api_principal&.coordinator?
    return true if current_api_principal&.id.to_s == trade.agent.agent_id.to_s

    render json: { error: "Forbidden" }, status: :forbidden
    false
  end

  def require_research_writer_api_principal!
    return false unless require_api_principal!
    return true if current_api_principal&.internal?
    return true if current_api_principal&.coordinator?
    return true if current_api_principal&.analyst?

    render json: { error: "Forbidden" }, status: :forbidden
    false
  end

  def bearer_token
    authorization = request.authorization.to_s
    scheme, token = authorization.split(/\s+/, 2)
    return nil unless scheme&.casecmp("Bearer")&.zero?

    token.to_s.strip.presence
  end

  def authenticate_api_principal(token)
    return nil if token.blank?

    internal_token = AppConfig.trading_api_internal_token.to_s
    return ApiPrincipal.new(id: "internal", type: :internal) if secure_token_match?(token, internal_token)

    AppConfig.trading_api_agent_tokens.each do |agent_id, agent_token|
      next unless secure_token_match?(token, agent_token)

      agent_id = agent_id.to_s
      return ApiPrincipal.new(id: agent_id, type: api_principal_type_for_agent(agent_id))
    end

    nil
  end

  def api_principal_type_for_agent(agent_id)
    return :coordinator if agent_id == "tiverton"
    return :analyst if Agent.find_by(agent_id: agent_id)&.analyst?

    :agent
  end

  def secure_token_match?(provided, expected)
    return false if provided.blank? || expected.blank?

    ActiveSupport::SecurityUtils.secure_compare(
      Digest::SHA256.hexdigest(provided),
      Digest::SHA256.hexdigest(expected)
    )
  end
end
