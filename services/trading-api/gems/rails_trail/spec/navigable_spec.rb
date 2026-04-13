require "spec_helper"
require "rails_trail/navigable"
require "rails_trail/trail_definition"
require "rails_trail/move"

class Order < ActiveRecord::Base
  extend RailsTrail::Navigable::ClassMethods

  trail :status do
    from :pending, can: [:ship, :cancel]
    from :shipped, can: [:deliver, :return]
    from :delivered, can: [:refund], if: -> { delivered_at && delivered_at > 30.days.ago }
  end
end

RSpec.describe RailsTrail::Navigable do
  describe "#next_moves" do
    it "returns moves for current state" do
      order = Order.new(status: "pending")
      moves = order.next_moves
      expect(moves.map(&:action)).to contain_exactly("ship", "cancel")
    end

    it "returns empty for terminal state" do
      order = Order.new(status: "refunded")
      expect(order.next_moves).to eq([])
    end

    it "evaluates if: lambdas on the instance" do
      order = Order.new(status: "delivered", delivered_at: 10.days.ago)
      expect(order.next_moves.map(&:action)).to eq(["refund"])
    end

    it "excludes moves where if: lambda returns false" do
      order = Order.new(status: "delivered", delivered_at: 60.days.ago)
      expect(order.next_moves).to eq([])
    end

    it "includes description when provided" do
      klass = Class.new(ActiveRecord::Base) do
        self.table_name = "orders"
        extend RailsTrail::Navigable::ClassMethods
        trail :status do
          from :pending, can: [:ship], description: "Ship the order"
        end
      end
      order = klass.new(status: "pending")
      expect(order.next_moves.first.description).to eq("Ship the order")
    end
  end

  describe ".trail_definition" do
    it "stores the trail definition on the class" do
      expect(Order.trail_definition).to be_a(RailsTrail::TrailDefinition)
    end

    it "knows the state column" do
      expect(Order.trail_definition.state_column).to eq(:status)
    end
  end
end
