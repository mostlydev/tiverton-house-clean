module RailsTrail
  module AasmAdapter
    module_function

    # Returns an array of Move structs for events valid from current_state.
    # exposed_events: nil means all, array of strings means filter.
    def moves_for(record, current_state, exposed_events)
      return [] unless record.class.respond_to?(:aasm)

      state_sym = current_state.to_sym
      seen = {}
      moves = []

      record.class.aasm.events.each do |event|
        # Check if this event has a transition from the current state
        next unless event.transitions.any? { |t| Array(t.from).include?(state_sym) }

        normalized = normalize_event_name(event.name.to_s, current_state)

        # Filter by expose list (matches against normalized name)
        if exposed_events
          next unless exposed_events.include?(normalized)
        end

        # Deduplicate normalized names
        next if seen[normalized]
        seen[normalized] = true

        moves << Move.new(action: normalized, http_method: nil, path: nil, description: nil)
      end

      moves
    end

    # Strips _from_<state> suffixes: "cancel_from_proposed" -> "cancel"
    def normalize_event_name(event_name, current_state)
      suffix = "_from_#{current_state}".downcase
      if event_name.downcase.end_with?(suffix)
        event_name[0..-(suffix.length + 1)]
      else
        event_name
      end
    end
  end
end
