require "rails_trail/describe/name_deriver"
require "rails_trail/describe/model_schema_typer"
require "rails_trail/describe/path_params_extractor"

module RailsTrail
  module Describe
    class ToolSchemaBuilder
      JSON_BODY_METHODS = %w[POST PUT PATCH DELETE].freeze
      BODY_KEY_METHODS = %w[POST PUT PATCH].freeze

      def build(controller:, action:, method:, path:, dsl:, extracted_params:, model_class:)
        name = dsl[:name] || NameDeriver.derive(controller: controller, action: action.to_s)
        description = dsl[:description] || "TODO: #{name}"
        read_only = dsl.key?(:read_only) ? dsl[:read_only] : method.to_s.upcase == "GET"
        http_path = normalize_http_path(dsl[:path] || path, model_class)
        body_key = (dsl[:body_key] || extracted_params[:body_key])&.to_s

        http = {
          "method" => method.to_s.upcase,
          "path" => http_path
        }
        if body_key && JSON_BODY_METHODS.include?(http["method"]) && !body_key.empty?
          http["body"] = "json"
          http["body_key"] = body_key if BODY_KEY_METHODS.include?(http["method"])
        end

        {
          name: name,
          description: description,
          inputSchema: build_input_schema(
            path: http_path,
            dsl: dsl,
            extracted_params: extracted_params,
            model_class: model_class
          ),
          http: http,
          annotations: {
            "readOnly" => read_only,
            "scope" => dsl.fetch(:scope).to_s
          }
        }
      end

      private

      def build_input_schema(path:, dsl:, extracted_params:, model_class:)
        return { "type" => "object" } if extracted_params[:unresolved]

        schema = { "type" => "object" }
        properties = {}
        required = []

        PathParamsExtractor.extract(path).each do |param_name|
          properties[param_name.to_s] = { "type" => "string" }
          required << param_name.to_s
        end

        body_properties = filtered_body_properties(extracted_params[:properties] || [], dsl)
        body_property_names = body_properties.map(&:to_s)
        array_properties = extracted_params[:array_properties] || {}

        body_properties.each do |property|
          prop_name = property.to_s
          if array_properties[property]
            properties[prop_name] = { "type" => "array", "items" => { "type" => array_properties[property] } }
          else
            properties[prop_name] = { "type" => infer_property_type(model_class, property) }
          end
        end

        apply_query_params(properties, required, dsl[:query])

        if dsl[:required]
          dsl[:required].each do |name|
            required_name = name.to_s
            required << required_name if properties.key?(required_name) && !required.include?(required_name)
          end
        elsif model_class
          # Prefer explicit DSL required: lists for externally writable fields.
          # Model presence validators can include server-populated attributes.
          ModelSchemaTyper.required_attributes(model_class).each do |name|
            required_name = name.to_s
            next unless body_property_names.include?(required_name)

            required << required_name if properties.key?(required_name) && !required.include?(required_name)
          end
        end

        schema["properties"] = properties unless properties.empty?
        schema["required"] = required unless required.empty?
        schema
      end

      def filtered_body_properties(properties, dsl)
        filtered = properties.dup
        if dsl[:include_params]
          allowed = dsl[:include_params].map(&:to_sym)
          filtered = filtered.select { |name| allowed.include?(name.to_sym) }
        end
        if dsl[:exclude_params]
          rejected = dsl[:exclude_params].map(&:to_sym)
          filtered = filtered.reject { |name| rejected.include?(name.to_sym) }
        end
        filtered
      end

      def infer_property_type(model_class, property)
        return "string" unless model_class

        ModelSchemaTyper.type_for_column(model_class, property)
      end

      def apply_query_params(properties, required, query)
        return if query.nil?

        case query
        when Array
          query.each do |name|
            properties[name.to_s] ||= { "type" => "string" }
          end
        when Hash
          query.each do |name, meta|
            meta ||= {}
            entry = { "type" => meta[:type] || "string" }
            entry["description"] = meta[:description] if meta[:description]
            meta.each do |key, value|
              next if value.nil?
              next if %i[type description required].include?(key)

              entry[key.to_s] = value
            end
            properties[name.to_s] = entry
            if meta[:required]
              required_name = name.to_s
              required << required_name unless required.include?(required_name)
            end
          end
        end
      end

      def normalize_http_path(path, model_class)
        identifier = model_identifier(model_class)
        path.to_s.gsub(/:([a-zA-Z_][a-zA-Z0-9_]*)/) do
          raw_name = Regexp.last_match(1)
          name = raw_name == "id" && identifier ? identifier : raw_name
          "{#{name}}"
        end
      end

      def model_identifier(model_class)
        return nil unless model_class&.respond_to?(:trail_definition)

        id_method = model_class.trail_definition&.id_method
        return nil if id_method.nil? || id_method.to_s.empty? || id_method.to_s == "id"

        id_method.to_s
      end
    end
  end
end
