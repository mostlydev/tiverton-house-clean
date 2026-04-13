module RailsTrail
  module Responses
    module ClassMethods
      def trail_responses(**defaults)
        before_action { @_trail_responses_enabled = true }
        @_trail_response_defaults = defaults
      end

      def trail_response_defaults
        @_trail_response_defaults || {}
      end
    end

    module InstanceMethods
      def render(options = nil, *args, &block)
        if options.is_a?(Hash) && @_trail_responses_enabled
          trail_opt = options.delete(:trail)
          # trail: false means skip enrichment
          unless trail_opt == false
            if options[:json]
              options[:json] = Responses.enrich_payload(options[:json], trail: trail_opt)
            end
          end
        end
        super
      end
    end

    # Enriches a payload with next_moves.
    # trail: can be a model instance (explicit), nil (auto-detect), or false (skip).
    def self.enrich_payload(payload, trail:)
      return payload if trail == false

      if trail && trail.respond_to?(:next_moves)
        # Explicit model passed — merge next_moves into hash payload
        return enrich_hash(payload, trail)
      end

      if payload.respond_to?(:next_moves)
        return enrich_model(payload)
      end

      if payload.is_a?(Array)
        return payload.map { |item| enrich_payload(item, trail: nil) }
      end

      payload
    end

    def self.enrich_hash(hash, model)
      hash = hash.dup if hash.is_a?(Hash)
      hash[:next_moves] = model.next_moves.map(&:as_json)
      hash
    end

    def self.enrich_model(model)
      raw = model.respond_to?(:as_json) ? model.as_json : {}
      json = raw.is_a?(Hash) ? raw.transform_keys(&:to_sym) : {}
      json[:next_moves] = model.next_moves.map(&:as_json)
      json
    end

    private_class_method :enrich_hash, :enrich_model
  end
end
