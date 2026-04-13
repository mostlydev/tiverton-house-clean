require "rails_trail/trail_definition"
require "rails_trail/move"

module RailsTrail
  module Navigable
    module ClassMethods
      def trail(column = nil, id: nil, &block)
        state_col = column || detect_state_column
        definition = TrailDefinition.new(state_column: state_col, id_method: id)
        definition.instance_eval(&block) if block

        self._trail_definition = definition

        include InstanceMethods unless method_defined?(:next_moves)
      end

      def trail_definition
        _trail_definition
      end

      private

      def _trail_definition=(defn)
        @_trail_definition = defn
      end

      def _trail_definition
        @_trail_definition
      end

      def detect_state_column
        if respond_to?(:aasm) && aasm.attribute_name
          aasm.attribute_name
        else
          :status
        end
      end
    end

    module InstanceMethods
      def next_moves
        definition = self.class.trail_definition
        return [] unless definition

        moves = definition.moves_for(self)

        # Resolve routes if route map available
        if RailsTrail.route_map
          moves.each do |move|
            resolved = RailsTrail.route_map.resolve(self.class, move.action, self)
            if resolved
              move.http_method = resolved[:method]
              move.path = resolved[:path]
            end
          end
        end

        moves
      end
    end
  end
end
