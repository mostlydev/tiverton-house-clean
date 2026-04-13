#!/usr/bin/env python3
# /// script
# requires-python = ">=3.10"
# dependencies = [
#     "requests>=2.31.0",
# ]
# ///
"""
Fetch fundamental financial data from the Financial Datasets API and store
it in the ticker_metrics store via the Rails bulk endpoint.

Usage:
    uv run fetch-fundamentals.py TICKER [--period quarterly|annual|ttm] [--limit N] [--json]
"""

import argparse
import json
import os
import sys
import time
from datetime import datetime, timezone

import requests

API_BASE_URL = os.environ.get("TRADING_API_BASE_URL") or os.environ.get("API_BASE_URL", "http://trading-api:4000")
FD_API_BASE = "https://api.financialdatasets.ai"

# ---------------------------------------------------------------------------
# Field mappings: Financial Datasets API field -> ticker_metrics metric name
# ---------------------------------------------------------------------------

INCOME_STATEMENT_MAP = {
    "revenue": "fs_income_revenue",
    "cost_of_revenue": "fs_income_cost_of_revenue",
    "gross_profit": "fs_income_gross_profit",
    "operating_expense": "fs_income_operating_expense",
    "operating_income": "fs_income_operating_income",
    "interest_expense": "fs_income_interest_expense",
    "ebit": "fs_income_ebit",
    "net_income": "fs_income_net_income",
    "earnings_per_share": "fs_income_eps",
    "earnings_per_share_diluted": "fs_income_eps_diluted",
    "dividends_per_common_share": "fs_income_dividends_per_share",
    "weighted_average_shares_diluted": "fs_income_shares_diluted",
    "research_and_development": "fs_income_rnd",
}

BALANCE_SHEET_MAP = {
    "total_assets": "fs_balance_total_assets",
    "current_assets": "fs_balance_current_assets",
    "cash_and_equivalents": "fs_balance_cash_and_equivalents",
    "total_liabilities": "fs_balance_total_liabilities",
    "current_liabilities": "fs_balance_current_liabilities",
    "total_debt": "fs_balance_total_debt",
    "shareholders_equity": "fs_balance_shareholders_equity",
    "retained_earnings": "fs_balance_retained_earnings",
    "outstanding_shares": "fs_balance_outstanding_shares",
    "inventory": "fs_balance_inventory",
    "goodwill_and_intangible_assets": "fs_balance_goodwill_and_intangibles",
}

CASH_FLOW_MAP = {
    "net_cash_flow_from_operations": "fs_cashflow_operations",
    "capital_expenditure": "fs_cashflow_capex",
    "net_cash_flow_from_investing": "fs_cashflow_investing",
    "net_cash_flow_from_financing": "fs_cashflow_financing",
    "free_cash_flow": "fs_cashflow_free_cash_flow",
    "dividends_and_other_cash_distributions": "fs_cashflow_dividends",
    "issuance_or_purchase_of_equity_shares": "fs_cashflow_buybacks",
    "depreciation_and_amortization": "fs_cashflow_depreciation",
    "share_based_compensation": "fs_cashflow_stock_comp",
    "change_in_cash_and_equivalents": "fs_cashflow_net_change",
}

VALUATION_MAP = {
    "price_to_earnings_ratio": "val_pe",
    "price_to_book_ratio": "val_pb",
    "price_to_sales_ratio": "val_ps",
    "enterprise_value_to_ebitda_ratio": "val_ev_ebitda",
    "enterprise_value_to_revenue_ratio": "val_ev_revenue",
    "peg_ratio": "val_peg",
    "free_cash_flow_yield": "val_fcf_yield",
    "enterprise_value": "val_enterprise_value",
}

PROFITABILITY_MAP = {
    "gross_margin": "profit_gross_margin",
    "operating_margin": "profit_operating_margin",
    "net_margin": "profit_net_margin",
    "return_on_equity": "profit_roe",
    "return_on_assets": "profit_roa",
    "return_on_invested_capital": "profit_roic",
}

GROWTH_MAP = {
    "revenue_growth": "growth_revenue_yoy",
    "earnings_growth": "growth_earnings_yoy",
    "earnings_per_share_growth": "growth_eps_yoy",
    "free_cash_flow_growth": "growth_fcf_yoy",
    "book_value_growth": "growth_book_value_yoy",
    "operating_income_growth": "growth_operating_income_yoy",
    "ebitda_growth": "growth_ebitda_yoy",
}

HEALTH_MAP = {
    "debt_to_equity": "health_debt_to_equity",
    "debt_to_assets": "health_debt_to_assets",
    "interest_coverage": "health_interest_coverage",
    "current_ratio": "health_current_ratio",
    "quick_ratio": "health_quick_ratio",
}

# Combined financial metrics map (all are derived)
FINANCIAL_METRICS_MAP = {
    **VALUATION_MAP,
    **PROFITABILITY_MAP,
    **GROWTH_MAP,
    **HEALTH_MAP,
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def parse_fiscal_period(report: dict) -> dict:
    """Extract period_end, fiscal_year, fiscal_quarter from an API report entry."""
    result = {}

    # report_period is the end date of the reporting period (YYYY-MM-DD)
    report_period = report.get("report_period")
    if report_period:
        result["period_end"] = report_period

    # period is like "quarterly", "annual", "ttm"
    period = report.get("period")
    if period:
        result["period_type"] = period

    # fiscal_period is like "2026-Q1", "2025-FY", or just "Q1", "FY"
    fiscal_period = report.get("fiscal_period")
    if fiscal_period:
        fp = fiscal_period.strip().upper()
        # Handle "YYYY-Q1" format
        if "-Q" in fp:
            parts = fp.split("-Q")
            try:
                result["fiscal_year"] = int(parts[0])
                result["fiscal_quarter"] = int(parts[1])
            except (ValueError, IndexError):
                pass
        # Handle "YYYY-FY" format
        elif "-FY" in fp:
            try:
                result["fiscal_year"] = int(fp.split("-FY")[0])
            except (ValueError, IndexError):
                pass
        # Handle bare "Q1" format
        elif fp.startswith("Q") and len(fp) == 2 and fp[1].isdigit():
            result["fiscal_quarter"] = int(fp[1])

    # fiscal_year from the report (integer) as fallback
    if "fiscal_year" not in result:
        fy = report.get("fiscal_year") or report.get("calendar_year")
        if fy is not None:
            try:
                result["fiscal_year"] = int(fy)
            except (ValueError, TypeError):
                pass

    return result


def fd_api_get(path: str, api_key: str, params: dict, max_retries: int = 3) -> dict | None:
    """GET from Financial Datasets API with retry on 429."""
    url = f"{FD_API_BASE}{path}"
    headers = {"X-API-KEY": api_key}

    for attempt in range(max_retries):
        try:
            resp = requests.get(url, headers=headers, params=params, timeout=30)
        except requests.RequestException as e:
            print(f"  Error fetching {path}: {e}", file=sys.stderr)
            return None

        if resp.status_code == 200:
            return resp.json()

        if resp.status_code == 429:
            wait = 2 ** attempt
            print(f"  Rate limited on {path}, retrying in {wait}s...", file=sys.stderr)
            time.sleep(wait)
            continue

        # Other errors: log and skip
        print(f"  HTTP {resp.status_code} on {path}: {resp.text[:200]}", file=sys.stderr)
        return None

    print(f"  Exhausted retries for {path}", file=sys.stderr)
    return None


def map_statement_metrics(
    records: list[dict],
    field_map: dict,
    ticker: str,
    is_derived: bool,
    observed_at: str,
) -> list[dict]:
    """Convert API statement records into ticker_metrics bulk entries."""
    metrics = []
    for record in records:
        period_info = parse_fiscal_period(record)
        period_type = period_info.get("period_type")

        for api_field, metric_name in field_map.items():
            value = record.get(api_field)
            if value is None:
                continue

            entry = {
                "ticker": ticker,
                "metric": metric_name,
                "value": value,
                "source": "financial_datasets",
                "observed_at": observed_at,
                "is_derived": is_derived,
            }
            if period_type:
                entry["period_type"] = period_type
            if "period_end" in period_info:
                entry["period_end"] = period_info["period_end"]
            if "fiscal_year" in period_info:
                entry["fiscal_year"] = period_info["fiscal_year"]
            if "fiscal_quarter" in period_info:
                entry["fiscal_quarter"] = period_info["fiscal_quarter"]

            metrics.append(entry)

    return metrics


def post_bulk_metrics(metrics: list[dict]) -> dict:
    """POST metrics to the Rails bulk endpoint."""
    url = f"{API_BASE_URL}/api/v1/ticker_metrics/bulk"
    payload = {"metrics": metrics}
    resp = requests.post(url, json=payload, timeout=30)
    resp.raise_for_status()
    return resp.json()


# ---------------------------------------------------------------------------
# Fetch functions for each data type
# ---------------------------------------------------------------------------


def fetch_income_statements(ticker: str, api_key: str, period: str, limit: int, observed_at: str) -> list[dict]:
    data = fd_api_get(
        "/financials/income-statements",
        api_key,
        {"ticker": ticker, "period": period, "limit": limit},
    )
    if not data:
        return []
    records = data.get("income_statements", [])
    if not records:
        return []
    return map_statement_metrics(records, INCOME_STATEMENT_MAP, ticker, is_derived=False, observed_at=observed_at)


def fetch_balance_sheets(ticker: str, api_key: str, period: str, limit: int, observed_at: str) -> list[dict]:
    data = fd_api_get(
        "/financials/balance-sheets",
        api_key,
        {"ticker": ticker, "period": period, "limit": limit},
    )
    if not data:
        return []
    records = data.get("balance_sheets", [])
    if not records:
        return []
    return map_statement_metrics(records, BALANCE_SHEET_MAP, ticker, is_derived=False, observed_at=observed_at)


def fetch_cash_flow_statements(ticker: str, api_key: str, period: str, limit: int, observed_at: str) -> list[dict]:
    data = fd_api_get(
        "/financials/cash-flow-statements",
        api_key,
        {"ticker": ticker, "period": period, "limit": limit},
    )
    if not data:
        return []
    records = data.get("cash_flow_statements", [])
    if not records:
        return []
    return map_statement_metrics(records, CASH_FLOW_MAP, ticker, is_derived=False, observed_at=observed_at)


def fetch_financial_metrics(ticker: str, api_key: str, period: str, limit: int, observed_at: str) -> list[dict]:
    data = fd_api_get(
        "/financial-metrics",
        api_key,
        {"ticker": ticker, "period": period, "limit": limit},
    )
    if not data:
        return []
    records = data.get("financial_metrics", [])
    if not records:
        return []
    return map_statement_metrics(records, FINANCIAL_METRICS_MAP, ticker, is_derived=True, observed_at=observed_at)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------


def main():
    parser = argparse.ArgumentParser(
        description="Fetch fundamentals from Financial Datasets API into ticker metrics store"
    )
    parser.add_argument("ticker", help="Stock ticker symbol (e.g. AAPL)")
    parser.add_argument(
        "--period",
        choices=["quarterly", "annual", "ttm"],
        default="quarterly",
        help="Reporting period (default: quarterly)",
    )
    parser.add_argument(
        "--limit",
        type=int,
        default=4,
        help="Number of periods to fetch (default: 4)",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        dest="json_output",
        help="Output results as JSON",
    )
    args = parser.parse_args()

    api_key = os.environ.get("FINANCIAL_DATASETS_API_KEY")
    if not api_key:
        print("Error: FINANCIAL_DATASETS_API_KEY environment variable is not set", file=sys.stderr)
        sys.exit(1)

    ticker = args.ticker.upper()
    observed_at = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    all_metrics = []

    # Fetch all 4 data types in sequence
    fetchers = [
        ("income statements", fetch_income_statements),
        ("balance sheets", fetch_balance_sheets),
        ("cash flow statements", fetch_cash_flow_statements),
        ("financial metrics", fetch_financial_metrics),
    ]

    for label, fetcher in fetchers:
        if not args.json_output:
            print(f"Fetching {label} for {ticker}...", file=sys.stderr)
        metrics = fetcher(ticker, api_key, args.period, args.limit, observed_at)
        all_metrics.extend(metrics)
        if not args.json_output:
            print(f"  {len(metrics)} metrics mapped", file=sys.stderr)

    if not all_metrics:
        if args.json_output:
            print(json.dumps({"ticker": ticker, "inserted": 0, "metrics": []}))
        else:
            print(f"No fundamental data available for {ticker}")
        sys.exit(0)

    # POST to Rails bulk endpoint
    try:
        result = post_bulk_metrics(all_metrics)
    except requests.RequestException as e:
        print(f"Error posting metrics to Rails API: {e}", file=sys.stderr)
        sys.exit(1)

    if args.json_output:
        print(json.dumps({
            "ticker": ticker,
            "inserted": result.get("inserted", 0),
            "metrics_count": len(all_metrics),
        }))
    else:
        inserted = result.get("inserted", 0)
        print(f"Inserted {inserted} metrics for {ticker}")


if __name__ == "__main__":
    main()
