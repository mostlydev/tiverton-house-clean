module RailsTrail
  class Configuration
    attr_accessor :service_name, :skill_output_path, :api_prefix,
                  :ai_model, :ai_api_key, :ai_base_url,
                  :descriptor_output_path, :descriptor_auth,
                  :descriptor_skill, :descriptor_description
    attr_reader :descriptor_feeds

    def initialize
      @api_prefix = "/api"
      @ai_base_url = "https://api.anthropic.com/v1/"
      @descriptor_feeds = []
    end

    def descriptor_feeds=(feeds)
      @descriptor_feeds = feeds || []
    end

    def service_name
      @service_name || default_service_name
    end

    private

    def default_service_name
      return nil unless defined?(Rails)
      Rails.application.class.module_parent_name.underscore.tr("/", "-")
    rescue
      nil
    end
  end
end
