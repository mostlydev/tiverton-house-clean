require "active_support/inflector"

module RailsTrail
  module Describe
    class NameDeriver
      CRUD_VERBS = {
        "index" => :list,
        "show" => :get,
        "create" => :create,
        "update" => :update,
        "destroy" => :delete
      }.freeze

      def self.derive(controller:, action:)
        resource_name = controller.to_s.split("/").last || controller.to_s
        action_name = action.to_s

        case CRUD_VERBS[action_name]
        when :list
          "list_#{resource_name}"
        when :get
          "get_#{resource_name.singularize}"
        when :create
          "create_#{resource_name.singularize}"
        when :update
          "update_#{resource_name.singularize}"
        when :delete
          "delete_#{resource_name.singularize}"
        else
          "#{action_name}_#{resource_name.singularize}"
        end
      end
    end
  end
end
