# Trade Approval Workflow

## Dual-Party Model

A trade requires two independent sign-offs before it can execute:

1. **Trader confirmation** — the trader confirms intent via the `confirm_trade` tool (sets `confirmed_at`).
2. **Compliance approval** — Tiverton (or a risk officer) approves via the `approve_trade` tool (sets `approved_at`).

These are independent. Either can happen first. Execution proceeds only when both are present.

## Advisory and Compliance

Tiverton has two jobs on each proposal:

- **Advisory:** Give one round of feedback in `#trading-floor` mentioning the proposing trader by Discord ID. Challenge the thesis, point out weaknesses. Do not deny purely on style, timing, or disagreement.
- **Compliance:** Run the hard-limit check defined in `risk-limits.md` and respect any current `trading-api` guard failures. The policy file is the source of truth for thresholds and notes which rules are API-enforced today. If a trade violates a hard limit, deny with the specific rule breach. If it is a documented rotation, evaluate the net projected slot count rather than the pre-fill snapshot alone.

Advisory and compliance can happen together or separately. Tiverton may approve immediately after advisory if the hard limits clearly pass, or wait if it needs to see updated state first.

## How state changes work

All trade state changes happen through managed tools (or the underlying API). Discord is a communication channel only.

- **Traders** call the `propose_trade`, `confirm_trade`, `pass_trade`, and `cancel_trade` tools.
- **Tiverton** calls the `approve_trade` or `deny_trade` tool.
- Posting "APPROVED", "CONFIRMED", "DENIED", etc. in Discord text does **not** change trade state. The API record is the only source of truth.
- Discord reactions and emoji are not workflow signals. Do not interpret them as confirmation or approval.

## Desk Rules

- `trading-api` is the source of truth for state transitions.
- Use implied identity and pod surfaces; do not route approval work through legacy host paths.
- Agents should follow the `Next:` instruction emitted by the workflow.
- Approval should not re-litigate the advisory discussion.
- If a trader passes, close the loop and move on.
- Working notes stay private under `<repo-root>/storage/private/<agent>/`; only reusable desk artifacts belong on `<repo-root>/storage/shared/`.
