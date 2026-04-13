require "spec_helper"
require "aasm"
require "rails_trail/aasm_adapter"
require "rails_trail/move"

class Ticket < ActiveRecord::Base
  include AASM

  aasm column: :status do
    state :open, initial: true
    state :in_progress
    state :resolved
    state :closed

    event :start do
      transitions from: :open, to: :in_progress
    end

    event :resolve do
      transitions from: :in_progress, to: :resolved
    end

    event :close_from_open do
      transitions from: :open, to: :closed
    end

    event :close_from_resolved do
      transitions from: :resolved, to: :closed
    end

    event :close do
      transitions from: [:open, :in_progress, :resolved], to: :closed
    end
  end
end

RSpec.describe RailsTrail::AasmAdapter do
  describe ".moves_for" do
    it "returns events valid from current state" do
      ticket = Ticket.new(status: "open")
      moves = described_class.moves_for(ticket, "open", nil)
      actions = moves.map(&:action)
      expect(actions).to include("start", "close")
    end

    it "does not return events for other states" do
      ticket = Ticket.new(status: "open")
      moves = described_class.moves_for(ticket, "open", nil)
      expect(moves.map(&:action)).not_to include("resolve")
    end

    it "normalizes _from_<state> suffixed events" do
      ticket = Ticket.new(status: "open")
      moves = described_class.moves_for(ticket, "open", nil)
      actions = moves.map(&:action)
      # close_from_open should normalize to "close"
      expect(actions.count("close")).to eq(1)
    end

    it "deduplicates normalized events from same state" do
      ticket = Ticket.new(status: "resolved")
      moves = described_class.moves_for(ticket, "resolved", nil)
      actions = moves.map(&:action)
      # close_from_resolved and close both valid — should produce one "close"
      expect(actions.count("close")).to eq(1)
    end

    it "filters to exposed events" do
      ticket = Ticket.new(status: "open")
      moves = described_class.moves_for(ticket, "open", ["start"])
      expect(moves.map(&:action)).to eq(["start"])
    end

    it "expose filter matches normalized names" do
      ticket = Ticket.new(status: "open")
      # "close" should match both "close" and "close_from_open"
      moves = described_class.moves_for(ticket, "open", ["close"])
      expect(moves.map(&:action)).to eq(["close"])
    end
  end
end
