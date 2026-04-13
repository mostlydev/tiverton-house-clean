# frozen_string_literal: true

module RequestSurfaceGuard
  extend ActiveSupport::Concern

  private

  def block_public_web_access!
    return true unless AppConfig.public_web_host?(request.host)

    head :not_found
    false
  end

  def require_loopback_access!
    return true if loopback_request?

    head :not_found
    false
  end

  def loopback_request?
    ip = request.remote_ip.to_s
    ip == "127.0.0.1" || ip == "::1"
  end
end
