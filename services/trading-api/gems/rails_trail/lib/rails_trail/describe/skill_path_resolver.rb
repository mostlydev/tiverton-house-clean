module RailsTrail
  module Describe
    class SkillPathResolver
      def initialize(config, rails_root:, env: ENV)
        @config = config
        @rails_root = rails_root
        @env = env
      end

      def resolve
        explicit_path || pod_env_path || pod_detected_path || fallback_path
      end

      private

      def service_name
        @config.service_name
      end

      def explicit_path
        @config.skill_output_path
      end

      def pod_env_path
        pod_root = @env["CLAW_POD_ROOT"]
        return nil unless pod_root

        File.join(pod_root, "services", service_name, "docs", "skills", "#{service_name}.md")
      end

      def pod_detected_path
        # Walk up from rails_root looking for claw-pod.yml
        # Expect pattern: <pod_root>/services/<name>/
        dir = @rails_root
        2.times do
          parent = File.dirname(dir)
          break if parent == dir
          if File.exist?(File.join(parent, "claw-pod.yml"))
            return File.join(parent, "services", service_name, "docs", "skills", "#{service_name}.md")
          end
          dir = parent
        end
        nil
      end

      def fallback_path
        File.join(@rails_root, "docs", "skills", "#{service_name}.md")
      end
    end
  end
end
