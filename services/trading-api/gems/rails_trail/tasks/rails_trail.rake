namespace :rails_trail do
  desc "Generate AI-powered service manual skill file"
  task describe: :environment do
    require "rails_trail/describe/introspector"
    require "rails_trail/describe/prompt_builder"
    require "rails_trail/describe/skill_path_resolver"
    require "rails_trail/describe/generator"

    RailsTrail::Describe::Generator.new.generate
  end

  desc "Show introspected route and model data (no LLM call)"
  task introspect: :environment do
    require "rails_trail/describe/introspector"
    require "json"

    data = RailsTrail::Describe::Introspector.new.introspect
    puts JSON.pretty_generate(data)
  end

  desc "Generate deterministic .claw-describe.json v2 from routes + DSL"
  task claw_describe: :environment do
    require "rails_trail/describe/claw_descriptor_generator"

    path = RailsTrail::Describe::ClawDescriptorGenerator.new.generate
    puts "RailsTrail: wrote descriptor to #{path}"
  end
end
