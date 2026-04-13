# frozen_string_literal: true

require_relative "lib/rails_trail/version"

Gem::Specification.new do |spec|
  spec.name          = "rails_trail"
  spec.version       = RailsTrail::VERSION
  spec.authors       = ["Tiverton House"]
  spec.summary       = "State-aware next_moves for Rails APIs and AI-generated service manuals."
  spec.homepage      = "https://github.com/tiverton-house/rails_trail"
  spec.license       = "MIT"
  spec.required_ruby_version = ">= 3.1"

  spec.files = Dir["lib/**/*", "tasks/**/*", "LICENSE", "README.md"]
  spec.require_paths = ["lib"]

  spec.add_dependency "railties", ">= 7.0"
  spec.add_dependency "activerecord", ">= 7.0"
  spec.add_dependency "actionpack", ">= 7.0"

  spec.add_development_dependency "rspec-rails", "~> 6.0"
  spec.add_development_dependency "sqlite3", ">= 1.4"
  spec.add_development_dependency "aasm", "~> 5.5"
  spec.add_development_dependency "factory_bot_rails", "~> 6.2"
end
