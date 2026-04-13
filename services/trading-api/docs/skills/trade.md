---
name: "trade"
description: "Authoritative trading-api workflow for Clawdapus trading desk agents."
---

# trading-api trade manual

This manual describes the injected `trading-api.*` tool surface.
Use those tools for any trade workflow, quote, position, market-context, or watchlist action exposed in `CLAWDAPUS.md`.
Do not use shell wrappers or raw HTTP for tool-exposed trading actions.
If a required trading tool is missing or failing, treat that as a system issue.

## Purpose

- Traders: propose, inspect, confirm, pass, or cancel trades.
- Tiverton: review desk state, approve or deny after advisory review, and run desk operations.
- Monitors: inspect wallets, positions, stale proposals, and operations health.

## Core trade workflow

1. Inspect wallet and existing positions before proposing a trade.
2. Create a proposed trade with explicit thesis, risk, and sizing.
3. Two independent sign-offs are required before execution:
   - **Trader confirmation:** use `trading-api.confirm_trade` to confirm intent, or `trading-api.pass_trade` / `trading-api.cancel_trade` to decline.
   - **Compliance approval:** Tiverton gives one round of advisory feedback, then uses `trading-api.approve_trade` or `trading-api.deny_trade` based on hard-limit checks.
4. Either sign-off can happen first. Execution proceeds only when both are present.

Discord posts are advisory and routing context only.
The API record is the workflow truth. A Discord-only "confirm", "approve", or "pass" message does not change trade state.

## Identity and request shape

- Agent identity is derived from your auth token.
- For write tools such as `trading-api.propose_trade`, `trading-api.add_to_watchlist`, and `trading-api.remove_from_watchlist`, pass flat tool arguments only.
- Do not wrap fields under `trade` or `watchlist`; the tool bridge handles request shaping.
- Use field names exactly as the controller and tool schema expect: `qty_requested`, `amount_requested`, `is_urgent`, `asset_class`, `execution_policy`, `limit_price`, `stop_price`, `trail_percent`, `trail_amount`, `stop_loss`, and `target_price`.
- You must supply one of `qty_requested` or `amount_requested` on every proposal. For a tiny share flow test, use `qty_requested: 1`.
- `trail_percent` and `trail_amount` are executable trailing-stop fields only.
- Use `manual_trail_percent` or `manual_trail_amount` for advisory/manual trailing plans. Those fields are folded into `thesis` and do not place executable trailing stops.

## Read current state

- `trading-api.get_market_context` returns wallet balance, buying power, positions, and pending orders for the current agent.
- `trading-api.get_positions` lists current positions. `agent_id` is optional and usually unnecessary for agent callers.
- `trading-api.get_trade` returns the current state of a trade by `trade_id`.
- `trading-api.list_trades` lists trades and supports filters such as `status`, `ticker`, `agent_id`, and `limit`.
- `trading-api.get_watchlist` returns the current watchlist. Agent callers may omit `agent_id`; any supplied `agent_id` is ignored for agent callers.
- `trading-api.get_quote` returns a live quote for any ticker.
- `trading-api.get_ticker_news` returns recent news for a ticker.
- `trading-api.get_news_latest` returns the latest desk news summary.

## Research guard for BUY trades

For non-momentum equity and option BUY proposals, the API expects a populated research file at:

```text
<repo-root>/storage/shared/research/tickers/<TICKER>.md
```

The file must exist and must not still be the untouched template.
Momentum traders can skip this hard guard for fast entries, but should backfill the shared file once the setup is in play.
If you intentionally need to bypass that guard on any desk style, include `RESEARCH_OK` in the thesis.
Crypto pairs skip the research-file guard.

## Propose a trade

Use `trading-api.propose_trade` with flat arguments like:

```json
{
  "ticker": "NVDA",
  "side": "BUY",
  "amount_requested": 5000,
  "order_type": "MARKET",
  "thesis": "Momentum continuation through prior high on volume.",
  "stop_loss": 118,
  "target_price": 128,
  "execution_policy": "immediate"
}
```

For a manual trailing plan on a normal market order, prefer:

```json
{
  "ticker": "STAA",
  "side": "BUY",
  "qty_requested": 50,
  "order_type": "MARKET",
  "manual_trail_percent": 3,
  "thesis": "RESEARCH_OK post-earnings continuation with advisory trail."
}
```

Notes:

- You must send one of `qty_requested` or `amount_requested`. Omitting both is a fix-and-retry input error, not a reason to wait.
- Use `amount_requested` instead of `qty_requested` when sizing by dollars.
- Use `LIMIT`, `STOP`, `STOP_LIMIT`, or `TRAILING_STOP` only when you can supply the required price fields.
- `limit_price` is valid on `MARKET` if you intentionally want the API to auto-convert the order to `LIMIT`.
- Do not send `trail_percent` or `trail_amount` for a manual trailing plan. Use `manual_trail_percent`, `manual_trail_amount`, or `thesis` unless you are intentionally placing an executable `TRAILING_STOP`.
- Use `is_urgent: true` only for genuinely expedited cases.
- `SELL_ALL` and `COVER_ALL` are thesis tokens, not JSON booleans.
- For SELL without an existing position, include `SHORT_OK` in the thesis or the API will reject the trade.
- For notional SELL orders on equities/options, include `NOTIONAL_OK` in the thesis or the API will reject the trade.

The response includes the canonical `trade_id` to use for later confirm, pass, cancel, approve, or deny calls.

## After advisory

- Confirm a trade you still want with `trading-api.confirm_trade` and `trade_id`.
- Pass on a trade you no longer want with `trading-api.pass_trade` and `trade_id`.
- Cancel a trade that should no longer execute with `trading-api.cancel_trade`, `trade_id`, and optional `reason`.

Do not post "CONFIRM", "PASS", "CANCEL", "APPROVED", or "DENIED" in Discord as a substitute for these API calls.
State changes happen only through the API. Discord text does not affect trade state.

## Tiverton-only review actions

Workflow:

- On a `PROPOSED` trade: give one advisory response in Discord mentioning the trader, then run the mechanical compliance check.
- If hard limits pass: approve immediately via `trading-api.approve_trade`. Do not wait for the trader to confirm first.
- If a hard limit is violated: deny via `trading-api.deny_trade` with the exact rule breach.
- `APPROVED` without `confirmed_at` is normal. The trader still needs to confirm before execution proceeds.

## Trade guards that are currently enforced

- BUY proposals are rejected if another agent already holds the ticker.
- A second `PROPOSED` trade for the same agent+ticker updates the existing proposal instead of creating a new record.
- Notional orders (`amount_requested`) must use `order_type: "MARKET"` unless the asset class is crypto/crypto_perp.
- Options do not support `TRAILING_STOP`, extended-hours execution, or notional sizing.
- Crypto does not support short selling or `TRAILING_STOP`.
- `SELL_ALL` expands to this agent's full tracked long position at execution time.
- `COVER_ALL` expands to this agent's full tracked short position at execution time.

## Execution policy and market-hours behavior

- `execution_policy: "allow_extended"` lets eligible equity LIMIT orders queue for or execute in extended hours.
- `execution_policy: "queue_until_open"` always queues for the next regular market open.
- `execution_policy: "immediate"` executes now when the market/session allows it; otherwise it queues for the next regular open.
- During an active extended session, eligible LIMIT orders can still execute with `immediate` or `allow_extended`.
- Agents normally should not set `extended_hours` manually. The scheduler sets that flag when the approved trade is actually released for execution.

## Watchlist

- Use `trading-api.get_watchlist` to inspect the current watchlist.
- Use `trading-api.add_to_watchlist` with `ticker` or `tickers` to add names.
- Use `trading-api.remove_from_watchlist` with `ticker` or `tickers` to remove names.

Notes:

- Watchlists are API-owned state. Do not maintain a markdown watchlist mirror.
- Watchlist tickers that overlap with held positions are deduplicated in market context.
- Agent callers do not need to manage `agent_id` manually for watchlist mutation tools.

## Desk operations

- Use `trading-api.run_news_poll` to run the desk news poll immediately.
- Use `trading-api.check_alpaca_consistency` to compare broker state against Tiverton state.
- Use `trading-api.run_alpaca_alignment` for alignment. Set `apply: true` to write changes; omit it or pass `false` for dry run.

## Response enrichment

Every trade JSON response includes a `next_moves` array listing the concrete API actions
available for that trade in its current state. Each move contains `action`, `method`, and `path`.
Use `next_moves` to determine what you can do next. Do not hardcode state-machine logic.

## Working rules

- `trading-api` is the source of truth for trade state, wallet state, positions, and workflow transitions.
- The Discord conversation is advisory and routing context, not the canonical trade record.
- Always inspect the returned JSON before acting again.
- Keep the ticker, side, invalidation, and next action consistent between your Discord post and the API record.
- For Tiverton specifically: `PROPOSED` means advise and then approve or deny mechanically through the API. Approval and trader confirmation are independent dual-party sign-offs.
