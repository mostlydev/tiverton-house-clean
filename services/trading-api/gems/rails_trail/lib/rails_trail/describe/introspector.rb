require "active_support/inflector"

module RailsTrail
  module Describe
    class Introspector
      def initialize(rails_app: Rails.application)
        @app = rails_app
      end

      def introspect
        {
          service_name: RailsTrail.configuration.service_name,
          routes: introspect_routes,
          models: introspect_models
        }
      end

      private

      def introspect_routes
        prefix = RailsTrail.configuration.api_prefix
        @app.routes.routes.filter_map do |route|
          path = route.path.spec.to_s.gsub("(.:format)", "")
          next unless path.start_with?(prefix)

          verb = route.verb.to_s.strip
          verb = nil if verb.empty?
          verb = verb.scan(/[A-Z]+/).first if verb && !verb.match?(/\A[A-Z]+\z/)
          action = route.defaults[:action]
          controller = route.defaults[:controller]

          entry = {
            method: verb || "GET",
            path: path,
            action: [controller, action].compact.join("#"),
            controller: controller,
            action_name: action
          }

          controller_class = resolve_controller_class(controller)
          if controller_class
            entry[:controller_class] = controller_class
            entry[:controller_source_path] = controller_source_path(controller_class, action)
            if controller_class.respond_to?(:_trail_tools)
              dsl_entry = controller_class._trail_tools[action.to_sym]
              entry[:dsl] = dsl_entry if dsl_entry
            end
          end

          entry
        end
      end

      def resolve_controller_class(controller_path)
        return nil if controller_path.nil? || controller_path.to_s.empty?

        ActiveSupport::Inflector.safe_constantize(
          "#{ActiveSupport::Inflector.camelize(controller_path.to_s)}Controller"
        )
      end

      def controller_source_path(controller_class, action_name)
        return nil unless controller_class.instance_methods(false).include?(action_name.to_sym)

        controller_class.instance_method(action_name.to_sym).source_location&.first
      end

      def introspect_models
        ActiveRecord::Base.descendants.filter_map do |model|
          next unless model.respond_to?(:trail_definition) && model.trail_definition

          defn = model.trail_definition
          data = { name: model.name, states: [], transitions: [], manual_moves: [] }

          if model.respond_to?(:aasm)
            data[:states] = model.aasm.states.map { |s| s.name.to_s }
            model.aasm.events.each do |event|
              event.transitions.each do |t|
                Array(t.from).each do |from_state|
                  data[:transitions] << {
                    event: event.name.to_s,
                    from: from_state.to_s,
                    to: t.to.to_s
                  }
                end
              end
            end
          end

          Array(defn.manual_moves).each do |mm|
            data[:manual_moves] << {
              state: mm[:state],
              action: mm[:action],
              description: mm[:description]
            }
          end

          data
        end
      end
    end
  end
end
