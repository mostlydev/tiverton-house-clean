# frozen_string_literal: true

# Adds a deferred constraint trigger to enforce double-entry balance.
# All ledger entries within a transaction must sum to zero.
class AddLedgerBalanceConstraint < ActiveRecord::Migration[7.2]
  def up
    # Create the function that validates balance
    execute <<-SQL
      CREATE OR REPLACE FUNCTION validate_ledger_transaction_balance()
      RETURNS TRIGGER AS $$
      DECLARE
        txn_sum NUMERIC;
        txn_id BIGINT;
      BEGIN
        -- Get the transaction ID from the NEW row
        txn_id := NEW.ledger_transaction_id;

        -- Calculate sum of all entries for this transaction
        SELECT COALESCE(SUM(amount), 0) INTO txn_sum
        FROM ledger_entries
        WHERE ledger_transaction_id = txn_id;

        -- Allow small tolerance for floating point
        IF ABS(txn_sum) > 0.00001 THEN
          RAISE EXCEPTION 'Ledger transaction % is unbalanced: sum = %', txn_id, txn_sum;
        END IF;

        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql;
    SQL

    # Create the deferred constraint trigger
    # CONSTRAINT triggers can be deferred to transaction end
    execute <<-SQL
      CREATE CONSTRAINT TRIGGER trg_ledger_balance_check
      AFTER INSERT OR UPDATE ON ledger_entries
      DEFERRABLE INITIALLY DEFERRED
      FOR EACH ROW
      EXECUTE FUNCTION validate_ledger_transaction_balance();
    SQL

    # Create an index to optimize the balance check
    add_index :ledger_entries, :ledger_transaction_id, name: 'idx_ledger_entries_txn_balance'
  end

  def down
    execute "DROP TRIGGER IF EXISTS trg_ledger_balance_check ON ledger_entries"
    execute "DROP FUNCTION IF EXISTS validate_ledger_transaction_balance()"
    remove_index :ledger_entries, name: 'idx_ledger_entries_txn_balance', if_exists: true
  end
end
