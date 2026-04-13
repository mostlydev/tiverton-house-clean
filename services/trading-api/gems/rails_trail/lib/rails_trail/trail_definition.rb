module RailsTrail
  class TrailDefinition
    attr_reader :state_column, :id_method, :manual_moves, :exposed_events

    def initialize(state_column: nil, id_method: nil)
      @state_column = state_column
      @id_method = id_method || :id
      @manual_moves = []
      @exposed_events = nil  # nil means "all"
    end

    def from(state, can:, description: nil, **options)
      Array(can).each do |action|
        @manual_moves << {
          state: state.to_s,
          action: action.to_s,
          if: options[:if],
          description: description
        }
      end
    end

    def expose(*event_names)
      @exposed_events = event_names.map(&:to_s)
    end

    def moves_for(record)
      current_state = record.send(state_column).to_s
      moves = []

      # AASM-discovered moves (added in Task 3)
      if record.class.respond_to?(:aasm) && exposed_events != []
        moves.concat(aasm_moves_for(record, current_state))
      end

      # Manual moves
      manual_moves.each do |mm|
        next unless mm[:state].casecmp?(current_state)
        if mm[:if]
          next unless record.instance_exec(&mm[:if])
        end
        moves << Move.new(
          action: mm[:action],
          http_method: nil,
          path: nil,
          description: mm[:description]
        )
      end

      # Deduplicate: manual moves override AASM moves with same action
      seen = {}
      moves.each_with_object([]) do |move, result|
        if seen[move.action]
          idx = result.index { |m| m.action == move.action }
          result[idx] = move if idx && move.description
        else
          seen[move.action] = true
          result << move
        end
      end
    end

    private

    def aasm_moves_for(record, current_state)
      require "rails_trail/aasm_adapter"
      AasmAdapter.moves_for(record, current_state, exposed_events)
    end
  end
end
