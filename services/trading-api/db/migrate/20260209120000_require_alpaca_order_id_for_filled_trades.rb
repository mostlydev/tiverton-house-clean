# frozen_string_literal: true

class RequireAlpacaOrderIdForFilledTrades < ActiveRecord::Migration[7.1]
  def up
    # Audit and fix existing violations — mark as FAILED
    execute <<-SQL
      UPDATE trades
      SET status = 'FAILED',
          execution_error = 'Retroactively FAILED: FILLED without alpaca_order_id (phantom prevention)'
      WHERE status IN ('FILLED', 'PARTIALLY_FILLED')
        AND alpaca_order_id IS NULL;
    SQL

    # Belt-and-suspenders DB constraint
    execute <<-SQL
      ALTER TABLE trades ADD CONSTRAINT check_filled_has_alpaca_order_id
        CHECK (status NOT IN ('FILLED', 'PARTIALLY_FILLED') OR alpaca_order_id IS NOT NULL);
    SQL
  end

  def down
    execute <<-SQL
      ALTER TABLE trades DROP CONSTRAINT IF EXISTS check_filled_has_alpaca_order_id;
    SQL
  end
end
