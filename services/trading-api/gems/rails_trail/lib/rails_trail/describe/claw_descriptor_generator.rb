require "fileutils"
require "json"
require "active_support/inflector"

require "rails_trail/describe/introspector"
require "rails_trail/describe/strong_params_extractor"
require "rails_trail/describe/tool_schema_builder"

module RailsTrail
  module Describe
    class ClawDescriptorGenerator
      def initialize(config: RailsTrail.configuration, introspector: nil)
        @config = config
        @introspector = introspector || Introspector.new
        @builder = ToolSchemaBuilder.new
      end

      def generate
        raise "descriptor_output_path not configured" if @config.descriptor_output_path.to_s.empty?

        Rails.application.eager_load! if defined?(Rails) && Rails.application

        data = @introspector.introspect
        descriptor = {
          "version" => 2,
          "description" => @config.descriptor_description.to_s,
          "feeds" => Array(@config.descriptor_feeds).map { |entry| stringify_keys(entry) },
          "tools" => build_tools(data[:routes]),
          "auth" => stringify_keys(@config.descriptor_auth || {}),
          "skill" => @config.descriptor_skill.to_s
        }

        descriptor.delete("description") if descriptor["description"].empty?
        descriptor.delete("feeds") if descriptor["feeds"].empty?
        descriptor.delete("auth") if descriptor["auth"].empty?
        descriptor.delete("skill") if descriptor["skill"].empty?

        output_path = @config.descriptor_output_path
        FileUtils.mkdir_p(File.dirname(output_path))
        File.write(output_path, JSON.pretty_generate(descriptor) + "\n")
        output_path
      end

      private

      def build_tools(routes)
        routes.filter_map do |route|
          next unless route[:dsl]

          extracted = extract_params(route)
          model_class = resolve_model_class(route[:controller])
          tool = @builder.build(
            controller: route[:controller],
            action: route[:action_name],
            method: route[:method],
            path: route[:path],
            dsl: route[:dsl],
            extracted_params: extracted,
            model_class: model_class
          )

          stringify_keys(tool)
        end.sort_by { |tool| tool["name"] }
      end

      def extract_params(route)
        source_path = route[:controller_source_path]
        return { body_key: nil, properties: [], array_properties: {}, unresolved: false } unless source_path && File.exist?(source_path)

        source = File.read(source_path)
        StrongParamsExtractor.new(source: source).extract(action: route[:action_name])
      rescue ArgumentError
        { body_key: nil, properties: [], array_properties: {}, unresolved: false }
      end

      def resolve_model_class(controller_path)
        resource = controller_path.to_s.split("/").last.to_s
        model_name = ActiveSupport::Inflector.camelize(ActiveSupport::Inflector.singularize(resource))
        return nil if model_name.empty?

        ActiveSupport::Inflector.safe_constantize(model_name)
      end

      def stringify_keys(value)
        case value
        when Hash
          value.each_with_object({}) do |(key, nested_value), hash|
            hash[key.to_s] = stringify_keys(nested_value)
          end
        when Array
          value.map { |entry| stringify_keys(entry) }
        else
          value
        end
      end
    end
  end
end
