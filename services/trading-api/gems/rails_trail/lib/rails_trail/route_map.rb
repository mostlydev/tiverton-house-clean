module RailsTrail
  class RouteMap
    def initialize
      @routes = {}  # { "trades" => { "approve" => { method:, path_template: } } }
      @loaded = false
    end

    def register(resource, action, method:, path_template:)
      @routes[resource] ||= {}
      @routes[resource][action.to_s] = { method: method, path_template: path_template }
    end

    def lookup(resource, action)
      @routes.dig(resource, action.to_s)
    end

    def resolve(model_class, action, record)
      ensure_loaded!
      resource = resource_name_for(model_class)
      entry = lookup(resource, action.to_s)
      return nil unless entry

      id_method = (model_class.respond_to?(:trail_definition) && model_class.trail_definition&.id_method) || :id
      id_value = record.send(id_method)

      {
        method: entry[:method],
        path: entry[:path_template].gsub(":id", id_value.to_s)
      }
    end

    def resource_name_for(model_class)
      model_class.table_name
    end

    def load_from_rails!
      return if @loaded || !defined?(Rails)

      prefix = RailsTrail.configuration.api_prefix
      Rails.application.routes.routes.each do |route|
        path = route.path.spec.to_s.gsub("(.:format)", "")
        next unless path.start_with?(prefix)

        # Match member actions: /api/v1/<resource>/:id/<action>
        if (match = path.match(%r{#{Regexp.escape(prefix)}/(\w+)/:id/(\w+)\z}))
          resource = match[1]
          action = match[2]
          method = route.verb.to_s.presence || extract_verb(route)
          register(resource, action, method: method, path_template: path)
        end

        # Match collection/CRUD: /api/v1/<resource> (create, index, etc.)
        if (match = path.match(%r{#{Regexp.escape(prefix)}/(\w+)\z}))
          resource = match[1]
          verb = route.verb.to_s.presence || extract_verb(route)
          action_name = route.defaults[:action]
          register(resource, action_name, method: verb, path_template: path) if action_name
        end
      end

      @loaded = true
    end

    private

    def ensure_loaded!
      load_from_rails! unless @loaded
    end

    def extract_verb(route)
      if route.respond_to?(:verb)
        v = route.verb
        v.is_a?(String) ? v : v.to_s.scan(/[A-Z]+/).first
      else
        "GET"
      end
    end
  end
end
