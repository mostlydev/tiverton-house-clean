module RailsTrail
  Move = Struct.new(:action, :http_method, :path, :description, keyword_init: true) do
    def as_json(*)
      h = { action: action, method: http_method, path: path }
      h[:description] = description if description
      h
    end
  end
end
