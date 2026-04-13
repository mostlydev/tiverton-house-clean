require "active_support/core_ext/class/attribute"

module RailsTrail
  module ToolRegistration
    VALID_SCOPES = %i[agent coordinator internal].freeze

    def self.extended(base)
      base.class_eval do
        class_attribute :_trail_tools, instance_writer: false, default: {}
      end
    end

    def trail_tool(action, scope: nil, name: nil, description: nil, body_key: nil, read_only: nil,
                   query: nil, path: nil, include_params: nil, exclude_params: nil, required: nil)
      raise ArgumentError, "scope is required" if scope.nil?

      unless VALID_SCOPES.include?(scope)
        raise ArgumentError, "scope must be one of #{VALID_SCOPES.inspect}, got #{scope.inspect}"
      end

      entry = {
        scope: scope,
        name: name,
        description: description,
        body_key: body_key,
        read_only: read_only,
        query: normalize_query(query),
        path: path,
        include_params: normalize_param_list(include_params),
        exclude_params: normalize_param_list(exclude_params),
        required: normalize_param_list(required)
      }

      self._trail_tools = _trail_tools.merge(action.to_sym => entry)
    end

    private

    def normalize_query(query)
      case query
      when nil
        nil
      when Array
        query.map(&:to_sym)
      when Hash
        query.each_with_object({}) do |(key, value), normalized|
          normalized[key.to_sym] = value.is_a?(Hash) ? value.transform_keys(&:to_sym) : value
        end
      else
        query
      end
    end

    def normalize_param_list(values)
      return nil if values.nil?

      Array(values).map(&:to_sym)
    end
  end
end
