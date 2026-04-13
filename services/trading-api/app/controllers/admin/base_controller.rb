require "digest"

module Admin
  class BaseController < ActionController::Base
    protect_from_forgery with: :exception
    include RequestSurfaceGuard
    before_action :require_loopback_access!
    before_action :authenticate_admin

    layout "admin"

    private

    def authenticate_admin
      authenticate_or_request_with_http_basic("Admin Area") do |username, password|
        valid_admin_credentials?(username, password)
      end
    end

    def valid_admin_credentials?(username, password)
      return false unless AppConfig.admin_credentials_configured?

      secure_compare_digest(username, AppConfig.admin_username) &&
        secure_compare_digest(password, AppConfig.admin_password)
    end

    def secure_compare_digest(actual, expected)
      ActiveSupport::SecurityUtils.secure_compare(
        Digest::SHA256.hexdigest(actual.to_s),
        Digest::SHA256.hexdigest(expected.to_s)
      )
    end
  end
end
