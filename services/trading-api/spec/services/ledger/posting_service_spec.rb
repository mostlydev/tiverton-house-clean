# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Ledger::PostingService do
  let(:agent) { create(:agent) }

  def build_posting(**overrides)
    described_class.new(
      source_type: 'test',
      source_id: 'test-123',
      agent: agent,
      asset: 'USD',
      **overrides
    )
  end

  describe '#post!' do
    it 'creates a balanced transaction with entries' do
      posting = build_posting
      posting.add_entry(account_code: 'cash', amount: 100.0, asset: 'USD')
      posting.add_entry(account_code: 'equity', amount: -100.0, asset: 'USD')

      txn = posting.post!

      expect(txn).to be_a(LedgerTransaction)
      expect(txn.ledger_txn_id).to start_with('TXN-')
      expect(txn.source_type).to eq('test')
      expect(txn.ledger_entries.count).to eq(2)
    end

    it 'assigns sequential entry_seq numbers' do
      posting = build_posting
      posting.add_entry(account_code: 'cash', amount: 500.0, asset: 'USD')
      posting.add_entry(account_code: 'position', amount: -500.0, asset: 'USD')

      txn = posting.post!
      seqs = txn.ledger_entries.order(:entry_seq).pluck(:entry_seq)
      expect(seqs).to eq([1, 2])
    end

    it 'supports multi-entry postings (3+ legs)' do
      posting = build_posting
      posting.add_entry(account_code: 'cash', amount: 1000.0, asset: 'USD')
      posting.add_entry(account_code: 'position', amount: -800.0, asset: 'USD')
      posting.add_entry(account_code: 'fees', amount: -200.0, asset: 'USD')

      txn = posting.post!
      expect(txn.ledger_entries.count).to eq(3)
    end

    it 'stores description and metadata' do
      posting = build_posting(description: 'Test buy AAPL')
      posting.add_entry(account_code: 'cash', amount: -5000.0, asset: 'USD')
      posting.add_entry(account_code: 'position', amount: 5000.0, asset: 'USD')

      txn = posting.post!
      expect(txn.description).to eq('Test buy AAPL')
      expect(txn.agent).to eq(agent)
    end
  end

  describe 'validation' do
    it 'rejects fewer than 2 entries' do
      posting = build_posting
      posting.add_entry(account_code: 'cash', amount: 100.0, asset: 'USD')

      expect { posting.post! }.to raise_error(
        Ledger::PostingService::InvalidEntryError,
        /at least 2 entries/
      )
    end

    it 'rejects entries missing account_code' do
      posting = build_posting
      posting.add_entry(account_code: '', amount: 100.0, asset: 'USD')
      posting.add_entry(account_code: 'equity', amount: -100.0, asset: 'USD')

      expect { posting.post! }.to raise_error(
        Ledger::PostingService::InvalidEntryError,
        /account_code is required/
      )
    end

    it 'rejects entries missing asset' do
      posting = build_posting
      posting.add_entry(account_code: 'cash', amount: 100.0, asset: '')
      posting.add_entry(account_code: 'equity', amount: -100.0, asset: 'USD')

      expect { posting.post! }.to raise_error(
        Ledger::PostingService::InvalidEntryError,
        /asset is required/
      )
    end

    it 'rejects unbalanced entries' do
      posting = build_posting
      posting.add_entry(account_code: 'cash', amount: 100.0, asset: 'USD')
      posting.add_entry(account_code: 'equity', amount: -50.0, asset: 'USD')

      expect { posting.post! }.to raise_error(
        Ledger::PostingService::UnbalancedPostingError,
        /do not balance/
      )
    end

    it 'tolerates tiny rounding differences within BALANCE_TOLERANCE' do
      posting = build_posting
      posting.add_entry(account_code: 'cash', amount: 100.000001, asset: 'USD')
      posting.add_entry(account_code: 'equity', amount: -100.000001, asset: 'USD')

      expect { posting.post! }.not_to raise_error
    end
  end

  describe '#post (non-raising)' do
    it 'returns true on success' do
      posting = build_posting
      posting.add_entry(account_code: 'cash', amount: 100.0, asset: 'USD')
      posting.add_entry(account_code: 'equity', amount: -100.0, asset: 'USD')

      expect(posting.post).to be true
    end

    it 'returns false on failure and populates errors' do
      posting = build_posting
      posting.add_entry(account_code: 'cash', amount: 100.0, asset: 'USD')

      expect(posting.post).to be false
      expect(posting.errors).not_to be_empty
    end
  end

  describe 'agent resolution' do
    it 'resolves agent from agent_id string' do
      posting = build_posting(agent: agent.agent_id)
      posting.add_entry(account_code: 'cash', amount: 100.0, asset: 'USD')
      posting.add_entry(account_code: 'equity', amount: -100.0, asset: 'USD')

      txn = posting.post!
      expect(txn.agent).to eq(agent)
    end

    it 'accepts Agent object directly' do
      posting = build_posting(agent: agent)
      posting.add_entry(account_code: 'cash', amount: 100.0, asset: 'USD')
      posting.add_entry(account_code: 'equity', amount: -100.0, asset: 'USD')

      txn = posting.post!
      expect(txn.agent).to eq(agent)
    end
  end

  describe 'add_entry chaining' do
    it 'returns self for method chaining' do
      posting = build_posting
      result = posting.add_entry(account_code: 'cash', amount: 100.0, asset: 'USD')
      expect(result).to eq(posting)
    end
  end
end
