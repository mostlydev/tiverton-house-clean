require "spec_helper"

require "rails_trail/describe/model_schema_typer"
require "active_record"
require "tempfile"

ActiveRecord::Schema.define do
  suppress_messages do
    create_table :typed_things, force: true do |t|
      t.string :name, null: false
      t.integer :qty
      t.decimal :price, precision: 10, scale: 2
      t.boolean :is_active
      t.datetime :starts_at
      t.json :metadata
    end
  end
end

class TypedThing < ActiveRecord::Base
  validates :name, presence: true
end

class OfflineTypedThing
  def self.columns_hash
    raise ActiveRecord::ConnectionNotEstablished, "database unavailable"
  end

  def self.table_name
    "typed_things"
  end
end

RSpec.describe RailsTrail::Describe::ModelSchemaTyper do
  describe ".type_for_column" do
    it "maps string to string" do
      expect(described_class.type_for_column(TypedThing, :name)).to eq("string")
    end

    it "maps integer to integer" do
      expect(described_class.type_for_column(TypedThing, :qty)).to eq("integer")
    end

    it "maps decimal to number" do
      expect(described_class.type_for_column(TypedThing, :price)).to eq("number")
    end

    it "maps boolean to boolean" do
      expect(described_class.type_for_column(TypedThing, :is_active)).to eq("boolean")
    end

    it "maps datetime to string" do
      expect(described_class.type_for_column(TypedThing, :starts_at)).to eq("string")
    end

    it "maps json to object" do
      expect(described_class.type_for_column(TypedThing, :metadata)).to eq("object")
    end

    it "returns string for unknown columns" do
      expect(described_class.type_for_column(TypedThing, :nonexistent)).to eq("string")
    end

    it "falls back to schema.rb when the database is unavailable" do
      schema_file = Tempfile.new(["schema", ".rb"])
      schema_file.write(<<~RUBY)
        ActiveRecord::Schema[7.2].define(version: 1) do
          create_table "typed_things", force: :cascade do |t|
            t.integer "qty"
            t.decimal "price"
          end
        end
      RUBY
      schema_file.close

      expect(
        described_class.type_for_column(OfflineTypedThing, :qty, schema_path: schema_file.path)
      ).to eq("integer")
      expect(
        described_class.type_for_column(OfflineTypedThing, :price, schema_path: schema_file.path)
      ).to eq("number")
    ensure
      schema_file&.unlink
    end
  end

  describe ".required_attributes" do
    it "returns presence-validated attributes" do
      expect(described_class.required_attributes(TypedThing)).to contain_exactly(:name)
    end
  end
end
