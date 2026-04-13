# Ticker Metrics Naming Guide

This guide defines naming conventions for the unified ticker metrics store. The goal is consistency across agents, scripts, and APIs.

## General Rules
- All metric keys are lowercase snake_case.
- Prefer stable, descriptive names over provider-specific labels.
- Use semantic prefixes to group related data.
- Use suffixes for time windows or frequencies when applicable (e.g., `_1h`, `_1d`, `_qoq`, `_yoy`).

## Prefixes
- `price_` — price and returns
- `volume_` — volume and liquidity
- `social_` — social mentions and engagement
- `sentiment_` — polarity or sentiment scores
- `news_` — news-derived signals
- `fs_income_` — income statement line items
- `fs_balance_` — balance sheet line items
- `fs_cashflow_` — cash flow line items
- `val_` — valuation metrics (P/E, P/S, EV/EBITDA)
- `profit_` — profitability metrics (ROE, margins)
- `growth_` — growth metrics (YoY, QoQ)
- `health_` — balance sheet / leverage health metrics
- `analyst_` — estimates and consensus

## Examples
- `social_mentions_1h`
- `sentiment_score`
- `price_return_1d`
- `volume_avg_30d`
- `news_event_score`
- `fs_income_revenue`
- `fs_income_net_income`
- `fs_balance_cash_and_equivalents`
- `fs_cashflow_free_cash_flow`
- `val_pe`
- `val_ev_ebitda`
- `profit_roe`
- `growth_revenue_yoy`
- `health_debt_to_equity`
- `analyst_eps_estimate_next_quarter`

## Period Types (for fundamentals)
Use `period_type` to distinguish timescales:
- `quarterly`
- `annual`
- `ttm`

Period-related fields should be populated for statement metrics and derived fundamentals.

## Derived Metrics
Set `is_derived=true` for computed values (e.g., `profit_roe`, `growth_revenue_yoy`).

## Source Attribution
Always set `source` to the origin (API/provider/agent). Keep it stable and lowercase where possible (e.g., `financial_datasets`, `social_scan`).

Recommended sources:
- External providers: `financial_datasets`, `alpaca`, `finnhub`, `quiver`, `stockgeist`, `x_api`
- Internal agents/services: `social_scan`, `dundas`, `tiverton`, `metrics_ingest`, `fundamentals_fetcher`

Rules of thumb:
- Direct API data: use the provider name.
- Computed/merged metrics: use the agent or service name.
- Versioning details go in `meta`, not in `source`.
