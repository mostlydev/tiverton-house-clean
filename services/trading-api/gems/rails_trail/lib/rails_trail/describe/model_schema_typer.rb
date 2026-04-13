module RailsTrail
  module Describe
    class ModelSchemaTyper
      TYPE_MAP = {
        string: "string",
        text: "string",
        uuid: "string",
        integer: "integer",
        bigint: "integer",
        decimal: "number",
        float: "number",
        boolean: "boolean",
        datetime: "string",
        date: "string",
        time: "string",
        json: "object",
        jsonb: "object"
      }.freeze

      def self.type_for_column(model_class, column_name, schema_path: default_schema_path)
        return "string" unless model_class.respond_to?(:columns_hash)

        column = model_class.columns_hash[column_name.to_s]
        return "string" unless column

        TYPE_MAP[column.type] || "string"
      rescue ActiveRecord::ActiveRecordError
        type_from_schema_file(model_class, column_name, schema_path: schema_path)
      end

      def self.required_attributes(model_class)
        return [] unless model_class.respond_to?(:validators)

        model_class.validators.filter_map do |validator|
          next unless validator.respond_to?(:kind) && validator.kind == :presence

          validator.attributes
        end.flatten.uniq
      end

      def self.default_schema_path
        return nil unless defined?(Rails) && Rails.respond_to?(:root) && Rails.root

        Rails.root.join("db", "schema.rb").to_s
      end

      def self.type_from_schema_file(model_class, column_name, schema_path:)
        return "string" unless model_class.respond_to?(:table_name)
        return "string" if schema_path.to_s.empty? || !File.exist?(schema_path)

        raw_type = schema_columns(schema_path).dig(model_class.table_name.to_s, column_name.to_s)
        return "string" unless raw_type

        TYPE_MAP[raw_type.to_sym] || "string"
      end

      def self.schema_columns(schema_path)
        @schema_columns ||= {}
        @schema_columns[schema_path] ||= parse_schema_file(schema_path)
      end

      def self.parse_schema_file(schema_path)
        tables = Hash.new { |hash, key| hash[key] = {} }
        current_table = nil

        File.foreach(schema_path) do |line|
          if (match = line.match(/^\s*create_table\s+"([^"]+)"/))
            current_table = match[1]
            next
          end

          if current_table && line.match?(/^\s*end\b/)
            current_table = nil
            next
          end

          next unless current_table

          match = line.match(/^\s*t\.(\w+)\s+"([^"]+)"/)
          next unless match

          type_name = match[1]
          column_name = match[2]
          next unless TYPE_MAP.key?(type_name.to_sym)

          tables[current_table][column_name] = type_name
        end

        tables
      end
    end
  end
end
