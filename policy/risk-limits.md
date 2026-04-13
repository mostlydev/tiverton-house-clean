# Risk Limits

This file is the canonical Tiverton desk risk policy. The system docs render this
markdown directly, and workflow docs should refer back here instead of restating
thresholds in multiple places.

## Hard Limits

| Limit | Threshold | Enforcement today |
|---|---|---|
| Single position (standard) | Max 25% of the agent wallet unless the operator explicitly overrides | Tiverton compliance review; not API-enforced today |
| Single position (urgent) | Max 15% of the agent wallet | Tiverton compliance review; not API-enforced today |
| Open positions | Fewer than 7 concurrent tickers per agent | Tiverton compliance review; rotation-aware slot guard not implemented yet |
| One-agent-per-ticker | No new BUY if another agent already holds the ticker | API-enforced at proposal time |
| Cash required | Wallet must have sufficient buying power | API-enforced at execution time |
| Forbidden tickers | See `forbidden-tickers.md` | Tiverton compliance review; not API-enforced today |

## Rotation Intent

- Treat the slot limit as a projected post-rotation limit, not a raw snapshot of
  currently filled positions.
- If a trader submits a close intended to free a slot and a replacement buy in
  the same rotation window, review the pair on net exposure and projected slot
  count.
- Until the API has a rotation-aware guard, Tiverton should not block a
  reasonable rotation solely because the closing leg has not filled yet.
- Partial trims do not free a slot. A slot opens only when the trader is
  flattening the ticker.

## Soft Limits

| Limit | Threshold | Action |
|---|---|---|
| Single sector | Max 60% of portfolio | Advisory flag, not enforced |
| Position loss | -20% from entry | Re-evaluate thesis; do not auto-exit |
| Portfolio loss | -15% from starting equity | Tighten new positions; do not halt automatically |
| Total exposure | Max 80% deployed | Advisory target; keep 20% reserve |

## Escalate Instead Of Approving

- Any single position above 30% of wallet
- Total portfolio exposure above 80%
- Requests involving a forbidden ticker
- First trade in a new instrument class or a new broker route
- Any agent down more than 15% on the week
- Portfolio or desk-level risk that exceeds published operating limits
- Any workflow that depends on missing private memory, missing shared research,
  or inconsistent storage roots
- Any request that feels off, underspecified, or operationally unsafe

## Circuit Breakers

- Agent down 20% from recent equity peak: auto-pause and boss review required
- Three consecutive denied trades: review the agent strategy before the next
  approval
- Portfolio down 10% in one day: pause all agents and escalate

## Profit-Taking Discipline

Let winners run. Do not trim for profit alone.

- Exit on thesis invalidation, not arbitrary profit targets
- Concentration trims become valid when a single position exceeds 40% of wallet
- 25% entry limits are sizing rules, not exit signals
- The hard trade is usually sitting on your hands, not clicking buttons
