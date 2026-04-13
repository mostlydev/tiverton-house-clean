module RailsTrail
  module Describe
    class PathParamsExtractor
      PARAM_PATTERN = /:([a-zA-Z_][a-zA-Z0-9_]*)|\{([a-zA-Z_][a-zA-Z0-9_]*)\}/
      IGNORED_PARAMS = %i[claw_id].freeze

      def self.extract(path)
        path.to_s.scan(PARAM_PATTERN).map do |colon_name, brace_name|
          name = colon_name && !colon_name.empty? ? colon_name : brace_name
          name.to_sym
        end.reject { |name| IGNORED_PARAMS.include?(name) }
      end
    end
  end
end
