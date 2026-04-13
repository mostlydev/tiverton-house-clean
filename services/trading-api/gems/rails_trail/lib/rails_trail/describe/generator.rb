module RailsTrail
  module Describe
    class Generator
      def initialize(config: RailsTrail.configuration)
        @config = config
      end

      def generate
        require "openai"

        introspection = Introspector.new.introspect
        prompts = PromptBuilder.new(introspection).build
        output_path = SkillPathResolver.new(
          @config,
          rails_root: Rails.root.to_s,
          env: ENV
        ).resolve

        puts "RailsTrail: Calling #{@config.ai_model} to generate service manual..."

        client = OpenAI::Client.new(
          access_token: @config.ai_api_key,
          uri_base: @config.ai_base_url
        )

        response = client.chat(
          parameters: {
            model: @config.ai_model,
            messages: [
              { role: "system", content: prompts[:system] },
              { role: "user", content: prompts[:user] }
            ],
            max_tokens: 8192
          }
        )

        content = response.dig("choices", 0, "message", "content")
        raise "LLM returned empty response" if content.blank?

        # Wrap with frontmatter if the LLM didn't include it
        unless content.start_with?("---")
          content = <<~FRONTMATTER + content
            ---
            name: "#{@config.service_name}"
            description: "Auto-generated service manual for #{@config.service_name}."
            generated_at: "#{Time.current.iso8601}"
            rails_trail_version: "#{RailsTrail::VERSION}"
            ---

          FRONTMATTER
        end

        FileUtils.mkdir_p(File.dirname(output_path))
        File.write(output_path, content)

        puts "RailsTrail: Skill file written to #{output_path}"
        output_path
      end
    end
  end
end
