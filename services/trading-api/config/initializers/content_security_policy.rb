# frozen_string_literal: true

Rails.application.configure do
  config.content_security_policy do |policy|
    policy.default_src :self
    policy.base_uri :self
    policy.connect_src :self, :https
    policy.font_src :self, :https, :data
    policy.form_action :self
    policy.frame_ancestors :none
    policy.img_src :self, :https, :data
    policy.object_src :none
    policy.script_src :self, :https
    policy.style_src :self, :https, :unsafe_inline
  end

  config.content_security_policy_nonce_generator = ->(_request) { SecureRandom.base64(16) }
  config.content_security_policy_nonce_directives = %w[script-src]
end
