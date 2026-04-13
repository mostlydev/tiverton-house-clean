# Chart of Accounts

This document describes the account codes used in the ledger for double-entry accounting.

## Account Code Structure

Account codes follow a hierarchical naming convention:
- `{entity}:{entity_id}:{account_type}`
- All accounts are prefixed by their owning entity
- Asset type is tracked separately in the `asset` column

## Agent Accounts (Per Trader)

Each trading agent has the following accounts:

### Position Accounts
- **Code:** `agent:{agent_id}:cash`
- **Asset:** `USD`
- **Purpose:** Cash balance for the agent
- **Debits:** Cash inflows (sells, deposits)
- **Credits:** Cash outflows (buys, withdrawals)

---

- **Code:** `agent:{agent_id}:{TICKER}`
- **Asset:** `{TICKER}` (e.g., `AAPL`, `TSLA`)
- **Purpose:** Position in a specific ticker
- **Debits:** Position increases (buys)
- **Credits:** Position decreases (sells)

### Realized P&L Accounts

- **Code:** `agent:{agent_id}:realized_pnl`
- **Asset:** `USD`
- **Purpose:** Running balance of realized profit/loss from closed positions
- **Debits:** Realized gains (positive P&L)
- **Credits:** Realized losses (negative P&L)
- **Balance Type:** Cumulative (does not reset)

---

- **Code:** `agent:{agent_id}:cost_basis_adjustment`
- **Asset:** `USD`
- **Purpose:** Balancing account for realized P&L double-entry
- **Debits:** Offsetting credits to realized_pnl (losses)
- **Credits:** Offsetting debits to realized_pnl (gains)
- **Balance Type:** Cumulative contra-account to realized_pnl

**Important:** Every realized P&L transaction creates two entries that balance to zero:
```
Debit:  agent:westin:realized_pnl         $500.00
Credit: agent:westin:cost_basis_adjustment $500.00
```

## System Accounts

### Control Accounts

- **Code:** `alpaca_cash_control`
- **Asset:** `USD`
- **Purpose:** Control account for Alpaca broker cash
- **Usage:** Tracks total cash held at Alpaca across all agents

---

- **Code:** `cash_suspense`
- **Asset:** `USD`
- **Purpose:** Temporary holding account for unallocated cash drift
- **Usage:** Used during reconciliation when cash discrepancies are detected

### Bootstrap Accounts

- **Code:** `opening_balance:{agent_id}`
- **Asset:** `USD`
- **Purpose:** Opening equity from Feb 4, 2026 bootstrap reconciliation
- **Usage:** One-time entry to establish agent starting balances
- **Flag:** All entries have `bootstrap_adjusted: true`

## Transaction Types by Source

### BrokerFill (Fill Execution)

When a fill is executed, two entries are created:

**Buy Fill:**
```
Debit:  agent:{agent_id}:{ticker}  (increase position)
Credit: agent:{agent_id}:cash       (decrease cash)
```

**Sell Fill:**
```
Debit:  agent:{agent_id}:cash       (increase cash)
Credit: agent:{agent_id}:{ticker}   (decrease position)
```

### PositionLot (Realized P&L)

When a position lot is closed, two additional entries are created:

**Realized Gain:**
```
Debit:  agent:{agent_id}:realized_pnl
Credit: agent:{agent_id}:cost_basis_adjustment
```

**Realized Loss:**
```
Debit:  agent:{agent_id}:cost_basis_adjustment
Credit: agent:{agent_id}:realized_pnl
```

Note: Losses are posted as negative amounts, so the double-entry reverses.

### ReconciliationProvenance (Bootstrap)

Used during the Feb 4, 2026 bootstrap to establish opening balances:

```
Debit:  agent:{agent_id}:cash
Debit:  agent:{agent_id}:{ticker_1}
Debit:  agent:{agent_id}:{ticker_2}
Credit: opening_balance:{agent_id}
```

## Querying P&L

### Total Realized P&L for an Agent

```sql
SELECT SUM(amount)
FROM ledger_entries
WHERE account_code = 'agent:westin:realized_pnl'
  AND asset = 'USD';
```

### P&L by Period

```sql
SELECT DATE(booked_at) as date, SUM(amount) as daily_pnl
FROM ledger_entries le
JOIN ledger_transactions lt ON le.ledger_transaction_id = lt.id
WHERE le.account_code = 'agent:westin:realized_pnl'
  AND lt.booked_at >= '2026-02-01'
GROUP BY DATE(booked_at)
ORDER BY date;
```

### Reconciliation Check

P&L in ledger should match sum of closed lots:

```sql
-- From ledger
SELECT SUM(amount) as ledger_pnl
FROM ledger_entries
WHERE account_code LIKE 'agent:%:realized_pnl';

-- From position lots
SELECT SUM(realized_pnl) as lots_pnl
FROM position_lots
WHERE closed_at IS NOT NULL;
```

These should match within $0.01 (floating point tolerance).

## Balance Validation

Every ledger transaction MUST balance to zero across all its entries:

```sql
SELECT lt.id, lt.ledger_txn_id, SUM(le.amount) as balance
FROM ledger_transactions lt
JOIN ledger_entries le ON le.ledger_transaction_id = lt.id
GROUP BY lt.id, lt.ledger_txn_id
HAVING ABS(SUM(le.amount)) > 0.00001;
```

This query should return zero rows. Any results indicate an unbalanced transaction.

## Migration Notes

- **Phase 1:** Forward realized P&L tracking (current)
- **Phase 2:** Feb 3-4 backfill from Alpaca historical fills
- **Phase 3:** Pre-Feb 3 assessment (Day Zero approach recommended)

All P&L tracking began Feb 3, 2026. Bootstrap lots from Feb 4 reconciliation have `bootstrap_adjusted: true` and establish opening cost basis for unrealized P&L but do NOT generate realized P&L entries.
