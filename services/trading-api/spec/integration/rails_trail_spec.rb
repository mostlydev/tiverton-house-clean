require "rails_helper"

RSpec.describe "RailsTrail integration" do
  let!(:agent) { create(:agent) }

  describe "Trade#next_moves" do
    it "returns confirm alongside AASM moves for PROPOSED unconfirmed trade" do
      trade = create(:trade, agent: agent, status: "PROPOSED", confirmed_at: nil)
      moves = trade.next_moves.map(&:action)
      expect(moves).to include("confirm", "pass", "cancel", "approve", "deny")
    end

    it "omits confirm for PROPOSED confirmed trade" do
      trade = create(:trade, agent: agent, status: "PROPOSED", confirmed_at: Time.current)
      moves = trade.next_moves.map(&:action)
      expect(moves).to include("approve", "deny", "cancel")
      expect(moves).not_to include("confirm")
    end

    it "returns empty for terminal states" do
      trade = create(:trade, agent: agent, status: "FILLED", alpaca_order_id: "test-123")
      expect(trade.next_moves).to be_empty
    end

    it "resolves paths using trade_id" do
      trade = create(:trade, agent: agent, status: "PROPOSED", confirmed_at: nil)
      confirm_move = trade.next_moves.find { |m| m.action == "confirm" }
      expect(confirm_move).to be_present
      expect(confirm_move.path).to include(trade.trade_id)
      expect(confirm_move.path).to end_with("/confirm")
    end
  end
end
