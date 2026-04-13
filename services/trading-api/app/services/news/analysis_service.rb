# frozen_string_literal: true

module News
  class AnalysisService
    def initialize(article, context)
      @article = article
      @context = context
      @model = AppConfig.news_ai_model
      @max_retries = AppConfig.news_ai_max_retries
      @retry_delay = AppConfig.news_ai_retry_delay_seconds
    end

    def call
      return failure("AI analysis disabled") unless enabled?

      api_key = AppConfig.openrouter_api_key
      return failure("OPENROUTER_API_KEY not set") if api_key.blank?

      prompt = build_prompt
      last_failure = nil

      @max_retries.times do |attempt|
        response = request_completion(api_key, prompt)
        return response if response[:success]

        last_failure = response
        retryable = response[:retryable]
        log_attempt_failure(response, attempt: attempt + 1, will_retry: retryable && attempt < @max_retries - 1)
        return response unless retryable

        sleep(@retry_delay) if attempt < @max_retries - 1
      end

      failure(exhausted_retry_message(last_failure), retryable: false)
    end

    private

    def enabled?
      AppConfig.news_ai_enabled?
    end

    def build_prompt
      headline = strip_html(@article.headline.to_s).presence || "No headline"
      content = strip_html(@article.content_or_summary.to_s)[0, AppConfig.news_ai_content_max_length]
      symbols = @article.symbols

      positions_text = format_positions
      watchlists_text = format_watchlists
      agents_text = format_agents

      template = AppConfig.news_ai_prompt_template
      template.gsub("{{headline}}", headline)
              .gsub("{{symbols}}", symbols.any? ? symbols.join(", ") : "None")
              .gsub("{{content}}", content)
              .gsub("{{positions}}", positions_text)
              .gsub("{{watchlists}}", watchlists_text)
              .gsub("{{agents}}", agents_text)
    end

    def request_completion(api_key, prompt)
      response = Faraday.post("https://openrouter.ai/api/v1/chat/completions") do |req|
        req.headers["Authorization"] = "Bearer #{api_key}"
        req.headers["Content-Type"] = "application/json"
        req.options.timeout = AppConfig.news_ai_timeout_seconds
        req.options.open_timeout = AppConfig.news_ai_open_timeout_seconds
        req.body = {
          model: @model,
          messages: [ { role: "user", content: prompt } ],
          response_format: { type: "json_object" },
          temperature: 0.3
        }.to_json
      end

      unless response.success?
        return failure(
          "API returned #{response.status}: #{truncate_error(response.body)}",
          retryable: retryable_status?(response.status)
        )
      end

      parsed = JSON.parse(response.body)
      content = extract_message_content(parsed.dig("choices", 0, "message", "content"))
      raw_analysis = JSON.parse(strip_json_fence(content))
      analysis = normalize_analysis(raw_analysis)

      unless analysis.is_a?(Hash)
        return failure("AI response must be a JSON object, got #{raw_analysis.class}")
      end

      missing = required_fields.reject { |key| analysis.key?(key) }
      return failure("Missing required fields: #{missing.join(', ')}") if missing.any?

      {
        success: true,
        impact: analysis["impact"],
        route_to: analysis["route_to"],
        auto_post: analysis["auto_post"],
        reasoning: analysis["reasoning"]
      }
    rescue JSON::ParserError => e
      failure("JSON parse error: #{e.message}", retryable: true)
    rescue Faraday::TimeoutError => e
      failure("Timeout: #{e.message}", retryable: true)
    rescue StandardError => e
      failure("Exception: #{e.class}: #{e.message}", retryable: true)
    end

    def format_positions
      positions = @context[:positions] || {}
      return "  (No positions currently held)" if positions.empty?

      positions.map { |agent, tickers| "  #{agent}: #{tickers.join(', ')}" }.join("\n")
    end

    def format_watchlists
      watchlists = @context[:watchlists] || {}
      return "  (No watchlists)" if watchlists.empty?

      watchlists.map { |agent, tickers| "  #{agent}: #{tickers.join(', ')}" }.join("\n")
    end

    def format_agents
      agents = @context[:agents] || {}
      return "  (No agent data)" if agents.empty?

      agents.map { |name, desc| "  #{name}: #{desc}" }.join("\n")
    end

    def strip_html(value)
      ActionView::Base.full_sanitizer.sanitize(value).gsub(/\s+/, " ").strip
    end

    def log_attempt_failure(response, attempt:, will_retry:)
      suffix = will_retry ? " (retrying)" : ""
      Rails.logger.warn(
        "News AI analysis attempt #{attempt}/#{@max_retries} failed for article #{@article.id}: #{response[:error]}#{suffix}"
      )
    end

    def exhausted_retry_message(last_failure)
      return "Max retries exceeded" if last_failure.blank?

      "#{last_failure[:error]} (after #{@max_retries} attempts)"
    end

    def truncate_error(value)
      value.to_s.gsub(/\s+/, " ").strip[0, 200].presence || "empty response"
    end

    def retryable_status?(status)
      code = status.to_i
      code == 429 || code >= 500
    end

    def required_fields
      %w[impact route_to auto_post reasoning]
    end

    def extract_message_content(value)
      case value
      when String
        value
      when Array
        text = value.filter_map do |part|
          case part
          when String
            part
          when Hash
            part["text"] || part[:text]
          end
        end.join
        text.presence || value.to_json
      when Hash
        value["text"] || value[:text] || value.to_json
      else
        value.to_s
      end
    end

    def strip_json_fence(value)
      text = value.to_s.strip
      text = text.sub(/\A```(?:json)?\s*/i, "")
      text.sub(/\s*```\z/, "")
    end

    def normalize_analysis(value)
      return value if value.is_a?(Hash)
      return normalize_analysis_array(value) if value.is_a?(Array)

      value
    end

    def normalize_analysis_array(values)
      return normalize_analysis(values.first) if values.length == 1

      hashes = values.select { |value| value.is_a?(Hash) }
      return values unless hashes.length == values.length

      complete = hashes.select { |value| required_fields.all? { |field| value.key?(field) } }
      return collapse_complete_analyses(complete) if complete.any?

      merged = {}
      hashes.each do |value|
        value.each do |key, entry_value|
          return values if merged.key?(key) && merged[key] != entry_value

          merged[key] = entry_value
        end
      end

      return merged if required_fields.all? { |field| merged.key?(field) }

      values
    end

    def collapse_complete_analyses(values)
      return values.first if values.length == 1

      {
        "impact" => values.map { |value| value["impact"].to_s.upcase }.max_by { |impact| impact_rank(impact) },
        "route_to" => values.flat_map { |value| Array(value["route_to"]) }.map(&:to_s).uniq,
        "auto_post" => values.any? { |value| value["auto_post"] },
        "reasoning" => values.map { |value| value["reasoning"].to_s.strip }.reject(&:empty?).uniq.join(" | ")
      }
    end

    def impact_rank(value)
      case value.to_s.upcase
      when "HIGH"
        3
      when "MEDIUM"
        2
      when "LOW"
        1
      else
        0
      end
    end

    def failure(message, retryable: false)
      { success: false, error: message, retryable: retryable }
    end
  end
end
