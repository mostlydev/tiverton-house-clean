# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Docs', type: :request do
  it 'renders the risk management section from the canonical markdown file' do
    get '/docs/risk-management'

    expect(response).to have_http_status(:ok)
    expect(response.body).to include('Source of truth:')
    expect(response.body).to include('rotation-aware slot guard not implemented yet')
    expect(response.body).to include('One-agent-per-ticker')
    expect(response.body).not_to include('<h1>Risk Limits</h1>')
  end
end
