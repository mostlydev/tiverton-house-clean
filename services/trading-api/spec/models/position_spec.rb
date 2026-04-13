require 'rails_helper'

RSpec.describe Position, type: :model do
  it 'is invalid for open positions without stop_loss' do
    position = build(:position, stop_loss: nil, qty: 10)

    expect(position).not_to be_valid
    expect(position.errors[:stop_loss]).to include('must be present for open positions')
  end

  it 'allows zero-quantity positions without stop_loss' do
    position = build(:position, stop_loss: nil, qty: 0)

    expect(position).to be_valid
  end
end
