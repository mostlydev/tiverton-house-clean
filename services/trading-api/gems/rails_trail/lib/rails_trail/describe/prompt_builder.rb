module RailsTrail
  module Describe
    class PromptBuilder
      def initialize(introspection)
        @data = introspection
      end

      def build
        {
          system: system_prompt,
          user: user_prompt
        }
      end

      private

      def system_prompt
        <<~PROMPT
          You are a technical writer producing a service manual for an AI agent that will operate a Rails API.

          Output format: Markdown with YAML frontmatter containing `name` and `description` fields.

          Rules:
          - Describe every endpoint with its HTTP method, path, and purpose.
          - For models with state machines, describe the full state progression diagram.
          - Include manually declared actions (non-state-machine moves) alongside state transitions.
          - Use the route and model data provided — do not invent endpoints or transitions.
          - Write for an AI agent consumer, not a human developer. Be precise and operational.
          - Include a section on wrapper scripts if the service is part of a pod with a scripts/ directory.
        PROMPT
      end

      def user_prompt
        sections = []
        sections << "# Service: #{@data[:service_name]}"
        sections << ""
        sections << "## Routes"
        sections << ""
        @data[:routes].each do |r|
          sections << "- #{r[:method]} #{r[:path]} → #{r[:action]}"
        end

        if @data[:models].any?
          sections << ""
          sections << "## Models with State Machines"
          @data[:models].each do |model|
            sections << ""
            sections << "### #{model[:name]}"
            sections << "States: #{model[:states].join(', ')}" if model[:states].any?

            if model[:transitions].any?
              sections << "Transitions:"
              model[:transitions].each do |t|
                sections << "  #{t[:from]} → #{t[:event]} → #{t[:to]}"
              end
            end

            if model[:manual_moves].any?
              sections << "Additional actions (non-state-machine):"
              model[:manual_moves].each do |mm|
                desc = mm[:description] ? " — #{mm[:description]}" : ""
                sections << "  From #{mm[:state]}: #{mm[:action]}#{desc}"
              end
            end
          end
        end

        sections.join("\n")
      end
    end
  end
end
