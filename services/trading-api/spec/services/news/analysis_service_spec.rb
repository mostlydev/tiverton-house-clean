# frozen_string_literal: true

require 'rails_helper'

RSpec.describe News::AnalysisService do
  let(:article) do
    article = create(:news_article,
      headline: 'Apple reports strong earnings',
      content: 'Apple Inc. reported quarterly earnings that beat expectations...'
    )
    create(:news_symbol, news_article: article, symbol: 'AAPL')
    article
  end

  let(:context) do
    {
      positions: { 'gerrard' => [ 'AAPL 100 shares' ] },
      watchlists: { 'logan' => [ 'MSFT', 'GOOGL' ] },
      agents: { 'gerrard' => 'Value investor', 'logan' => 'Growth stocks' }
    }
  end

  let(:service) { described_class.new(article, context) }

  describe '#call' do
    context 'when AI analysis is disabled' do
      before do
        allow(AppConfig).to receive(:news_ai_enabled?).and_return(false)
      end

      it 'returns failure with disabled message' do
        result = service.call

        expect(result[:success]).to be false
        expect(result[:error]).to eq('AI analysis disabled')
      end
    end

    context 'when API key is missing' do
      before do
        allow(AppConfig).to receive(:news_ai_enabled?).and_return(true)
        allow(AppConfig).to receive(:openrouter_api_key).and_return(nil)
      end

      it 'returns failure with missing key message' do
        result = service.call

        expect(result[:success]).to be false
        expect(result[:error]).to eq('OPENROUTER_API_KEY not set')
      end
    end

    context 'when API returns success' do
      let(:api_response) do
        {
          'choices' => [
            {
              'message' => {
                'content' => {
                  impact: 'HIGH',
                  route_to: [ 'gerrard' ],
                  auto_post: true,
                  reasoning: 'Strong earnings beat for held position AAPL'
                }.to_json
              }
            }
          ]
        }
      end

      before do
        allow(AppConfig).to receive(:news_ai_enabled?).and_return(true)
        allow(AppConfig).to receive(:openrouter_api_key).and_return('test-key')
        allow(AppConfig).to receive(:news_ai_model).and_return('test-model')
        allow(AppConfig).to receive(:news_ai_timeout_seconds).and_return(15)
        allow(AppConfig).to receive(:news_ai_open_timeout_seconds).and_return(5)
        allow(AppConfig).to receive(:news_ai_max_retries).and_return(3)
        allow(AppConfig).to receive(:news_ai_retry_delay_seconds).and_return(2)
        allow(AppConfig).to receive(:news_ai_content_max_length).and_return(2000)
        allow(AppConfig).to receive(:news_ai_prompt_template).and_return(
          "Analyze: {{headline}} {{symbols}} {{content}} {{positions}} {{watchlists}} {{agents}}"
        )

        stub_request(:post, "https://openrouter.ai/api/v1/chat/completions")
          .to_return(status: 200, body: api_response.to_json, headers: { 'Content-Type' => 'application/json' })
      end

      it 'returns successful analysis' do
        result = service.call

        expect(result[:success]).to be true
        expect(result[:impact]).to eq('HIGH')
        expect(result[:route_to]).to eq([ 'gerrard' ])
        expect(result[:auto_post]).to be true
        expect(result[:reasoning]).to include('earnings beat')
      end

      it 'sends correct prompt with interpolated values' do
        service.call

        expect(WebMock).to have_requested(:post, "https://openrouter.ai/api/v1/chat/completions")
          .with { |req|
            body = JSON.parse(req.body)
            prompt = body.dig('messages', 0, 'content')
            expect(prompt).to include('Apple reports strong earnings')
            expect(prompt).to include('AAPL')
            expect(prompt).to include('gerrard')
          }
      end

      it 'sends correct API headers and parameters' do
        service.call

        expect(WebMock).to have_requested(:post, "https://openrouter.ai/api/v1/chat/completions")
          .with(
            headers: {
              'Authorization' => 'Bearer test-key',
              'Content-Type' => 'application/json'
            },
            body: hash_including(
              model: 'test-model',
              response_format: { type: 'json_object' }
            )
          )
      end
    end

    context 'when API returns 500 error' do
      before do
        allow(AppConfig).to receive(:news_ai_enabled?).and_return(true)
        allow(AppConfig).to receive(:openrouter_api_key).and_return('test-key')
        allow(AppConfig).to receive(:news_ai_model).and_return('test-model')
        allow(AppConfig).to receive(:news_ai_timeout_seconds).and_return(15)
        allow(AppConfig).to receive(:news_ai_open_timeout_seconds).and_return(5)
        allow(AppConfig).to receive(:news_ai_max_retries).and_return(3)
        allow(AppConfig).to receive(:news_ai_retry_delay_seconds).and_return(0)
        allow(AppConfig).to receive(:news_ai_content_max_length).and_return(2000)
        allow(AppConfig).to receive(:news_ai_prompt_template).and_return("Test {{headline}}")

        stub_request(:post, "https://openrouter.ai/api/v1/chat/completions")
          .to_return(status: 500, body: 'Internal Server Error')
      end

      it 'retries max times and returns max retries exceeded' do
        result = service.call

        expect(result[:success]).to be false
        expect(result[:error]).to eq('API returned 500: Internal Server Error (after 3 attempts)')
        expect(WebMock).to have_requested(:post, "https://openrouter.ai/api/v1/chat/completions").times(3)
      end
    end

    context 'when API returns malformed JSON' do
      before do
        allow(AppConfig).to receive(:news_ai_enabled?).and_return(true)
        allow(AppConfig).to receive(:openrouter_api_key).and_return('test-key')
        allow(AppConfig).to receive(:news_ai_model).and_return('test-model')
        allow(AppConfig).to receive(:news_ai_timeout_seconds).and_return(15)
        allow(AppConfig).to receive(:news_ai_open_timeout_seconds).and_return(5)
        allow(AppConfig).to receive(:news_ai_max_retries).and_return(2)
        allow(AppConfig).to receive(:news_ai_retry_delay_seconds).and_return(0)
        allow(AppConfig).to receive(:news_ai_content_max_length).and_return(2000)
        allow(AppConfig).to receive(:news_ai_prompt_template).and_return("Test {{headline}}")

        stub_request(:post, "https://openrouter.ai/api/v1/chat/completions")
          .to_return(status: 200, body: '{"invalid json}', headers: { 'Content-Type' => 'application/json' })
      end

      it 'retries and returns max retries exceeded' do
        result = service.call

        expect(result[:success]).to be false
        expect(result[:error]).to include('JSON parse error:')
        expect(result[:error]).to include('(after 2 attempts)')
        expect(WebMock).to have_requested(:post, "https://openrouter.ai/api/v1/chat/completions").times(2)
      end
    end

    context 'when API returns incomplete response' do
      let(:incomplete_response) do
        {
          'choices' => [
            {
              'message' => {
                'content' => {
                  impact: 'HIGH',
                  reasoning: 'Strong earnings'
                }.to_json
              }
            }
          ]
        }
      end

      before do
        allow(AppConfig).to receive(:news_ai_enabled?).and_return(true)
        allow(AppConfig).to receive(:openrouter_api_key).and_return('test-key')
        allow(AppConfig).to receive(:news_ai_model).and_return('test-model')
        allow(AppConfig).to receive(:news_ai_timeout_seconds).and_return(15)
        allow(AppConfig).to receive(:news_ai_open_timeout_seconds).and_return(5)
        allow(AppConfig).to receive(:news_ai_max_retries).and_return(1)
        allow(AppConfig).to receive(:news_ai_retry_delay_seconds).and_return(0)
        allow(AppConfig).to receive(:news_ai_content_max_length).and_return(2000)
        allow(AppConfig).to receive(:news_ai_prompt_template).and_return("Test {{headline}}")

        stub_request(:post, "https://openrouter.ai/api/v1/chat/completions")
          .to_return(status: 200, body: incomplete_response.to_json, headers: { 'Content-Type' => 'application/json' })
      end

      it 'returns missing fields error' do
        result = service.call

        expect(result[:success]).to be false
        expect(result[:error]).to include('Missing required fields')
        expect(result[:error]).to include('route_to')
        expect(result[:error]).to include('auto_post')
      end
    end

    context 'when API returns a single-object array payload' do
      let(:array_wrapped_response) do
        {
          'choices' => [
            {
              'message' => {
                'content' => [
                  {
                    impact: 'HIGH',
                    route_to: [ 'gerrard' ],
                    auto_post: true,
                    reasoning: 'Wrapped in an array but otherwise valid'
                  }
                ].to_json
              }
            }
          ]
        }
      end

      before do
        allow(AppConfig).to receive(:news_ai_enabled?).and_return(true)
        allow(AppConfig).to receive(:openrouter_api_key).and_return('test-key')
        allow(AppConfig).to receive(:news_ai_model).and_return('test-model')
        allow(AppConfig).to receive(:news_ai_timeout_seconds).and_return(15)
        allow(AppConfig).to receive(:news_ai_open_timeout_seconds).and_return(5)
        allow(AppConfig).to receive(:news_ai_max_retries).and_return(3)
        allow(AppConfig).to receive(:news_ai_retry_delay_seconds).and_return(0)
        allow(AppConfig).to receive(:news_ai_content_max_length).and_return(2000)
        allow(AppConfig).to receive(:news_ai_prompt_template).and_return("Test {{headline}}")

        stub_request(:post, "https://openrouter.ai/api/v1/chat/completions")
          .to_return(status: 200, body: array_wrapped_response.to_json, headers: { 'Content-Type' => 'application/json' })
      end

      it 'unwraps the array and returns successful analysis' do
        result = service.call

        expect(result[:success]).to be true
        expect(result[:impact]).to eq('HIGH')
        expect(result[:route_to]).to eq([ 'gerrard' ])
        expect(result[:auto_post]).to be true
        expect(result[:reasoning]).to include('Wrapped in an array')
        expect(WebMock).to have_requested(:post, "https://openrouter.ai/api/v1/chat/completions").once
      end
    end

    context 'when API returns a multi-hash array payload with split fields' do
      let(:array_response) do
        {
          'choices' => [
            {
              'message' => {
                'content' => [
                  { impact: 'HIGH', route_to: [ 'gerrard' ] },
                  { auto_post: true, reasoning: 'Split across array entries' }
                ].to_json
              }
            }
          ]
        }
      end

      before do
        allow(AppConfig).to receive(:news_ai_enabled?).and_return(true)
        allow(AppConfig).to receive(:openrouter_api_key).and_return('test-key')
        allow(AppConfig).to receive(:news_ai_model).and_return('test-model')
        allow(AppConfig).to receive(:news_ai_timeout_seconds).and_return(15)
        allow(AppConfig).to receive(:news_ai_open_timeout_seconds).and_return(5)
        allow(AppConfig).to receive(:news_ai_max_retries).and_return(3)
        allow(AppConfig).to receive(:news_ai_retry_delay_seconds).and_return(0)
        allow(AppConfig).to receive(:news_ai_content_max_length).and_return(2000)
        allow(AppConfig).to receive(:news_ai_prompt_template).and_return("Test {{headline}}")

        stub_request(:post, "https://openrouter.ai/api/v1/chat/completions")
          .to_return(status: 200, body: array_response.to_json, headers: { 'Content-Type' => 'application/json' })
      end

      it 'merges the hashes and returns successful analysis' do
        result = service.call

        expect(result[:success]).to be true
        expect(result[:impact]).to eq('HIGH')
        expect(result[:route_to]).to eq([ 'gerrard' ])
        expect(result[:auto_post]).to be true
        expect(result[:reasoning]).to include('Split across array entries')
        expect(WebMock).to have_requested(:post, "https://openrouter.ai/api/v1/chat/completions").once
      end
    end

    context 'when API returns multiple complete analyses for one article' do
      let(:array_response) do
        {
          'choices' => [
            {
              'message' => {
                'content' => [
                  {
                    impact: 'HIGH',
                    route_to: [ 'dundas' ],
                    auto_post: true,
                    reasoning: 'Unity Software issued updated preliminary Q1 sales guidance.'
                  },
                  {
                    impact: 'HIGH',
                    route_to: [ 'dundas', 'gerrard' ],
                    auto_post: false,
                    reasoning: 'Vor Biopharma announced the pricing of a private placement.'
                  }
                ].to_json
              }
            }
          ]
        }
      end

      before do
        allow(AppConfig).to receive(:news_ai_enabled?).and_return(true)
        allow(AppConfig).to receive(:openrouter_api_key).and_return('test-key')
        allow(AppConfig).to receive(:news_ai_model).and_return('test-model')
        allow(AppConfig).to receive(:news_ai_timeout_seconds).and_return(15)
        allow(AppConfig).to receive(:news_ai_open_timeout_seconds).and_return(5)
        allow(AppConfig).to receive(:news_ai_max_retries).and_return(3)
        allow(AppConfig).to receive(:news_ai_retry_delay_seconds).and_return(0)
        allow(AppConfig).to receive(:news_ai_content_max_length).and_return(2000)
        allow(AppConfig).to receive(:news_ai_prompt_template).and_return("Test {{headline}}")

        stub_request(:post, "https://openrouter.ai/api/v1/chat/completions")
          .to_return(status: 200, body: array_response.to_json, headers: { 'Content-Type' => 'application/json' })
      end

      it 'collapses them into one article-level analysis' do
        result = service.call

        expect(result[:success]).to be true
        expect(result[:impact]).to eq('HIGH')
        expect(result[:route_to]).to match_array([ 'dundas', 'gerrard' ])
        expect(result[:auto_post]).to be true
        expect(result[:reasoning]).to include('Unity Software')
        expect(result[:reasoning]).to include('Vor Biopharma')
        expect(WebMock).to have_requested(:post, "https://openrouter.ai/api/v1/chat/completions").once
      end
    end

    context 'when API returns message content as text blocks' do
      let(:content_block_response) do
        {
          'choices' => [
            {
              'message' => {
                'content' => [
                  { 'type' => 'text', 'text' => "```json\n" },
                  { 'type' => 'text', 'text' => "{\"impact\":\"HIGH\",\"route_to\":[\"gerrard\"]," },
                  { 'type' => 'text', 'text' => "\"auto_post\":true,\"reasoning\":\"Block content\"}\n```" }
                ]
              }
            }
          ]
        }
      end

      before do
        allow(AppConfig).to receive(:news_ai_enabled?).and_return(true)
        allow(AppConfig).to receive(:openrouter_api_key).and_return('test-key')
        allow(AppConfig).to receive(:news_ai_model).and_return('test-model')
        allow(AppConfig).to receive(:news_ai_timeout_seconds).and_return(15)
        allow(AppConfig).to receive(:news_ai_open_timeout_seconds).and_return(5)
        allow(AppConfig).to receive(:news_ai_max_retries).and_return(3)
        allow(AppConfig).to receive(:news_ai_retry_delay_seconds).and_return(0)
        allow(AppConfig).to receive(:news_ai_content_max_length).and_return(2000)
        allow(AppConfig).to receive(:news_ai_prompt_template).and_return("Test {{headline}}")

        stub_request(:post, "https://openrouter.ai/api/v1/chat/completions")
          .to_return(status: 200, body: content_block_response.to_json, headers: { 'Content-Type' => 'application/json' })
      end

      it 'joins text blocks and parses the JSON payload' do
        result = service.call

        expect(result[:success]).to be true
        expect(result[:impact]).to eq('HIGH')
        expect(result[:route_to]).to eq([ 'gerrard' ])
        expect(result[:auto_post]).to be true
        expect(result[:reasoning]).to eq('Block content')
        expect(WebMock).to have_requested(:post, "https://openrouter.ai/api/v1/chat/completions").once
      end
    end

    context 'when API returns an array payload that cannot be normalized' do
      let(:array_response) do
        {
          'choices' => [
            {
              'message' => {
                'content' => [
                  { impact: 'HIGH', route_to: [ 'gerrard' ] },
                  { impact: 'LOW' }
                ].to_json
              }
            }
          ]
        }
      end

      before do
        allow(AppConfig).to receive(:news_ai_enabled?).and_return(true)
        allow(AppConfig).to receive(:openrouter_api_key).and_return('test-key')
        allow(AppConfig).to receive(:news_ai_model).and_return('test-model')
        allow(AppConfig).to receive(:news_ai_timeout_seconds).and_return(15)
        allow(AppConfig).to receive(:news_ai_open_timeout_seconds).and_return(5)
        allow(AppConfig).to receive(:news_ai_max_retries).and_return(3)
        allow(AppConfig).to receive(:news_ai_retry_delay_seconds).and_return(0)
        allow(AppConfig).to receive(:news_ai_content_max_length).and_return(2000)
        allow(AppConfig).to receive(:news_ai_prompt_template).and_return("Test {{headline}}")

        stub_request(:post, "https://openrouter.ai/api/v1/chat/completions")
          .to_return(status: 200, body: array_response.to_json, headers: { 'Content-Type' => 'application/json' })
      end

      it 'fails once with a shape error instead of raising and retrying' do
        result = service.call

        expect(result[:success]).to be false
        expect(result[:error]).to eq('AI response must be a JSON object, got Array')
        expect(WebMock).to have_requested(:post, "https://openrouter.ai/api/v1/chat/completions").once
      end
    end
  end

  describe '#build_prompt' do
    before do
      allow(AppConfig).to receive(:news_ai_content_max_length).and_return(100)
      allow(AppConfig).to receive(:news_ai_prompt_template).and_return(
        "H: {{headline}} S: {{symbols}} C: {{content}} P: {{positions}} W: {{watchlists}} A: {{agents}}"
      )
    end

    it 'interpolates all placeholders correctly' do
      prompt = service.send(:build_prompt)

      expect(prompt).to include('H: Apple reports strong earnings')
      expect(prompt).to include('S: AAPL')
      expect(prompt).to include('P:   gerrard: AAPL 100 shares')
      expect(prompt).to include('W:   logan: MSFT, GOOGL')
      expect(prompt).to include('A:   gerrard: Value investor')
    end

    it 'truncates content to max length' do
      article.update!(content: 'a' * 500)
      prompt = service.send(:build_prompt)

      # Content should be truncated to 100 chars
      content_match = prompt.match(/C: (.+?) P:/)
      expect(content_match[1].length).to eq(100)
    end

    it 'handles missing symbols gracefully' do
      article.news_symbols.destroy_all
      allow(AppConfig).to receive(:news_ai_prompt_template).and_return("S: {{symbols}}")

      prompt = service.send(:build_prompt)

      expect(prompt).to eq('S: None')
    end

    it 'handles empty context gracefully' do
      empty_service = described_class.new(article, {})
      allow(AppConfig).to receive(:news_ai_prompt_template).and_return(
        "P: {{positions}} W: {{watchlists}} A: {{agents}}"
      )

      prompt = empty_service.send(:build_prompt)

      expect(prompt).to include('P:   (No positions currently held)')
      expect(prompt).to include('W:   (No watchlists)')
      expect(prompt).to include('A:   (No agent data)')
    end
  end
end
