module RailsTrail
  class Railtie < Rails::Railtie
    initializer "rails_trail.extend_active_record" do
      ActiveSupport.on_load(:active_record) do
        extend RailsTrail::Navigable::ClassMethods
      end
    end

    initializer "rails_trail.extend_action_controller" do
      RailsTrail::Railtie.extend_controller!(ActionController::Base) if defined?(ActionController::Base)
      RailsTrail::Railtie.extend_controller!(ActionController::API) if defined?(ActionController::API)

      ActiveSupport.on_load(:action_controller_base) { RailsTrail::Railtie.extend_controller!(self) }
      ActiveSupport.on_load(:action_controller_api) { RailsTrail::Railtie.extend_controller!(self) }
    end

    rake_tasks do
      load File.expand_path("../../tasks/rails_trail.rake", __dir__)
    end

    def self.extend_controller!(klass)
      klass.extend RailsTrail::ToolRegistration unless klass.respond_to?(:trail_tool)
      klass.extend RailsTrail::Responses::ClassMethods unless klass.respond_to?(:trail_responses)
      klass.include RailsTrail::Responses::InstanceMethods unless klass < RailsTrail::Responses::InstanceMethods
    end
  end
end
