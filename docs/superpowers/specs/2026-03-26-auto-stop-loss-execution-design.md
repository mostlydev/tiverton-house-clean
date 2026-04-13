# Auto Stop Loss Execution

**Date:** 2026-03-26
**Status:** Approved

## Summary

Replace the current stop-loss notification flow (Discord message → manual agent action → Tiverton approval → execution) with automatic execution. When a position's price crosses its stop loss, the system creates a Trade record, bypasses Tiverton's approval workflow, executes the sell via Alpaca immediately, and posts a confirmation to Discord mentioning the owning trader.

## Architecture

### New Components

1. **`StopLossExecutionService`** — orchestrates the full flow:
   - Validates no duplicate stop-loss trade is already in-flight for this position
   - Creates a Trade record with `source: 'stop_loss_auto'` thesis marker
   - Sets `confirmed_at` immediately (bypasses advisory phase)
   - Approves (PROPOSED → APPROVED via AASM, guard passes because confirmed_at is set)
   - Executes via existing `TradeExecutionService`
   - Posts `[STOP LOSS EXECUTED]` to Discord with `<@trader_discord_id>` mention

2. **`StopLossExecutionJob`** — async Sidekiq job wrapping the service, so `PriceUpdateService` isn't blocked by Alpaca API calls.

### Modified Components

- **`PriceUpdateService#trigger_stop_loss_reminder!`** — instead of publishing to the outbox for notification, enqueue `StopLossExecutionJob`.
- **`Trade` model** — add `stop_loss_auto` scope and helper to detect auto-stop trades.

### Unchanged Components

- `TradeExecutionService` — reused as-is. Handles qty-based orders, multi-agent isolation, broker order recording, fill processing.
- `Trades::FillProcessorService` — handles position/ledger updates on fill.
- `Trades::GuardService` — validates execution guards.
- `OutboxPublisherService` — still publishes trade lifecycle events (proposed, approved, filled) for the auto-created trade.
- AASM state machine — full audit trail preserved.

## Trade Record Shape

```ruby
Trade.create!(
  agent: position.agent,
  ticker: position.ticker,
  side: "SELL",
  order_type: "MARKET",
  qty_requested: position.qty,
  asset_class: inferred_from_ticker,
  execution_policy: "immediate",
  thesis: "STOP_LOSS_AUTO: price $#{current_price} hit stop $#{stop_loss}. SELL_ALL.",
  is_urgent: true,
  extended_hours: false,
  confirmed_at: Time.current,
  approved_by: "stop_loss_auto",
  approved_at: Time.current
)
```

State flow: PROPOSED → (auto-approve) → APPROVED → EXECUTING → FILLED

## Discord Notification

Posted after fill (or after failure):

**Success:**
```
[STOP LOSS EXECUTED] EQT
<@1464508643742584904> your stop was triggered.
**Sold #{qty} @ $#{fill_price}** (stop was $#{stop_loss}, price hit $#{trigger_price})
Trade: #{trade_id}
```

**Failure:**
```
[STOP LOSS FAILED] EQT
<@1464508643742584904> auto-stop execution failed: #{error}
Price $#{current_price} <= Stop $#{stop_loss}
Manual action required.
```

## Safeguards

- **Dedupe:** Before creating the trade, check for existing non-terminal trades on the same position+agent with `STOP_LOSS_AUTO` in thesis. Skip if one exists.
- **Market hours:** Equities only execute when `MarketHours.market_data_active?` (already gated by PriceUpdateService). Crypto executes 24/7.
- **Qty isolation:** Uses `position.qty` for the specific agent, not a position close. `TradeExecutionService` already handles multi-agent ticker sharing.
- **Existing outbox notifications:** The old `StopLossNotificationJob` path is replaced. The outbox `stop_loss_triggered` event type is no longer published; instead, trade lifecycle events (proposed/approved/filled/failed) fire normally via the Trade model callbacks.

## Files to Create

- `app/services/stop_loss_execution_service.rb`
- `app/jobs/stop_loss_execution_job.rb`

## Files to Modify

- `app/services/price_update_service.rb` — call `StopLossExecutionJob` instead of outbox publish
- `app/models/trade.rb` — add `stop_loss_auto` scope
