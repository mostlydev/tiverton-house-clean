require "prism"

module RailsTrail
  module Describe
    class StrongParamsExtractor
      Result = Struct.new(:body_key, :properties, :array_properties, :unresolved, keyword_init: true) do
        def to_h
          {
            body_key: body_key,
            properties: properties || [],
            array_properties: array_properties || {},
            unresolved: unresolved
          }
        end
      end

      def initialize(source:)
        @source = source
        @ast = Prism.parse(source).value
        @method_index = build_method_index
      end

      def extract(action:)
        action_def = @method_index[action.to_sym]
        raise ArgumentError, "action :#{action} not found in source" unless action_def

        direct = scan_for_permit(action_def.body)
        return direct.to_h if direct

        helper_name = find_params_helper_call(action_def.body)
        if helper_name
          helper_def = @method_index[helper_name]
          return Result.new(body_key: nil, properties: [], array_properties: {}, unresolved: true).to_h unless helper_def

          helper_result = scan_for_permit(helper_def.body)
          return helper_result.to_h if helper_result

          return Result.new(body_key: nil, properties: [], array_properties: {}, unresolved: true).to_h
        end

        Result.new(body_key: nil, properties: [], array_properties: {}, unresolved: false).to_h
      end

      private

      def build_method_index
        index = {}
        walk(@ast) do |node|
          index[node.name] = node if node.is_a?(Prism::DefNode)
          nil
        end
        index
      end

      def scan_for_permit(body)
        # This returns the first static permit shape found while walking the AST.
        # Controllers with branch-specific permit lists should prefer explicit DSL overrides.
        find_first(body) do |node|
          extract_permit_result(node)
        end
      end

      def extract_permit_result(node)
        return nil unless node.is_a?(Prism::CallNode) && node.name == :permit

        receiver = node.receiver
        if receiver.is_a?(Prism::CallNode) && receiver.name == :require && params_call?(receiver.receiver)
          body_key = extract_symbol_argument(receiver.arguments&.arguments)
          return Result.new(body_key: nil, properties: [], array_properties: {}, unresolved: true) if body_key.nil?

          parsed = parse_permit_args(node.arguments&.arguments || [])
          return Result.new(body_key: body_key, properties: [], array_properties: {}, unresolved: true) if parsed.nil?

          return Result.new(
            body_key: body_key,
            properties: parsed[:properties],
            array_properties: parsed[:array_properties],
            unresolved: false
          )
        end

        return nil unless params_call?(receiver)

        parsed = parse_permit_args(node.arguments&.arguments || [])
        return Result.new(body_key: nil, properties: [], array_properties: {}, unresolved: true) if parsed.nil?

        Result.new(
          body_key: nil,
          properties: parsed[:properties],
          array_properties: parsed[:array_properties],
          unresolved: false
        )
      end

      def parse_permit_args(args)
        properties = []
        array_properties = {}

        args.each do |arg|
          case arg
          when Prism::SymbolNode
            properties << arg.unescaped.to_sym
          when Prism::KeywordHashNode, Prism::HashNode
            elements = arg.respond_to?(:elements) ? arg.elements : []
            elements.each do |assoc|
              return nil unless assoc.is_a?(Prism::AssocNode)

              key = assoc.key
              value = assoc.value
              return nil unless key.is_a?(Prism::SymbolNode)

              key_sym = key.unescaped.to_sym
              if value.is_a?(Prism::ArrayNode) && value.elements.empty?
                properties << key_sym
                array_properties[key_sym] = "string"
              else
                return nil
              end
            end
          else
            return nil
          end
        end

        { properties: properties, array_properties: array_properties }
      end

      def find_params_helper_call(body)
        find_first(body) do |node|
          next nil unless node.is_a?(Prism::CallNode)
          next nil unless node.name.to_s.end_with?("_params")
          next nil if node.receiver && !node.receiver.is_a?(Prism::SelfNode)

          node.name
        end
      end

      def extract_symbol_argument(args)
        return nil unless args&.length == 1
        return nil unless args.first.is_a?(Prism::SymbolNode)

        args.first.unescaped.to_sym
      end

      def params_call?(node)
        node.is_a?(Prism::CallNode) && node.name == :params && node.receiver.nil?
      end

      def find_first(node, &block)
        return nil unless node

        result = yield(node)
        return result if result

        node.child_nodes.each do |child|
          found = find_first(child, &block)
          return found if found
        end

        nil
      end

      def walk(node, &block)
        return unless node

        yield(node)
        node.child_nodes.each { |child| walk(child, &block) if child }
      end
    end
  end
end
