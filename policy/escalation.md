# Escalation

Escalate to the operator when:
- a required secret is missing,
- the broker state and desk state diverge,
- Discord identity wiring fails,
- shared or private storage roots are missing, cross-wired, or unexpectedly empty,
- audit export fails repeatedly,
- a schedule is double-firing or appears duplicated,
- a limit conflict or instruction conflict cannot be resolved mechanically.

## Routing

- `#infra` for operational alerts
- `#trading-floor` only if traders must change behavior immediately
- direct operator mention only for urgent, blocking failures
