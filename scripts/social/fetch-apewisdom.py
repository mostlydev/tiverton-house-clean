#!/usr/bin/env python3
# /// script
# requires-python = ">=3.10"
# dependencies = [
#     "requests>=2.31.0",
# ]
# ///
"""
Fetch ApeWisdom subreddit mention rankings and store in ticker_metrics.

Usage:
    uv run fetch-apewisdom.py --subreddit wallstreetbets [--window 1h|24h] [--limit N] [--holdings] [--json]
"""

import argparse
import json
import os
import sys
from datetime import datetime, timezone

import requests

API_BASE_URL = os.environ.get("TRADING_API_BASE_URL") or os.environ.get("API_BASE_URL", "http://trading-api:4000")
APEWISDOM_FILTERS = {
    "all-stocks": "https://apewisdom.io/api/v1.0/filter/all-stocks",
    "all-crypto": "https://apewisdom.io/api/v1.0/filter/all-crypto",
}


def post_bulk_metrics(metrics):
    url = f"{API_BASE_URL}/api/v1/ticker_metrics/bulk"
    payload = {"metrics": metrics}
    resp = requests.post(url, json=payload, timeout=30)
    resp.raise_for_status()
    return resp.json()


def fetch_holdings():
    url = f"{API_BASE_URL}/api/v1/positions"
    resp = requests.get(url, timeout=30)
    resp.raise_for_status()
    data = resp.json()
    positions = data.get("positions", data)
    tickers = {p.get("ticker", "").upper().strip() for p in positions if p.get("ticker")}
    return {t for t in tickers if t}


def normalize_ticker(ticker, filter_type):
    if filter_type == "all-crypto" and ticker.endswith(".X"):
        base = ticker[:-2]
        return f"{base}/USD"
    return ticker


def fetch_tradeable_symbols(asset_class):
    """Fetch tradeable symbols from Alpaca via the Rails assets endpoint."""
    url = f"{API_BASE_URL}/api/v1/assets"
    resp = requests.get(url, params={"asset_class": asset_class}, timeout=15)
    resp.raise_for_status()
    return set(resp.json().get("symbols", []))


def main():
    parser = argparse.ArgumentParser(description="Fetch ApeWisdom subreddit mentions into ticker metrics")
    parser.add_argument("--subreddit", default="wallstreetbets", help="Subreddit to query (default: wallstreetbets)")
    parser.add_argument("--window", default="24h", help="Metric window suffix (e.g., 1h, 24h)")
    parser.add_argument("--limit", type=int, default=100, help="Limit to top N tickers")
    parser.add_argument("--holdings", action="store_true", help="Filter results to current portfolio tickers")
    parser.add_argument("--filter", default="all-stocks", choices=sorted(APEWISDOM_FILTERS.keys()),
                        help="ApeWisdom filter (default: all-stocks)")
    parser.add_argument("--json", action="store_true", dest="json_output", help="Output summary as JSON")
    args = parser.parse_args()

    holdings = None
    if args.holdings:
        try:
            holdings = fetch_holdings()
        except requests.RequestException as exc:
            print(f"Error fetching holdings from API: {exc}", file=sys.stderr)
            sys.exit(1)

        if not holdings:
            if args.json_output:
                print(json.dumps({"inserted": 0, "metrics": 0, "reason": "no_holdings"}))
            else:
                print("No holdings found")
            return

        if args.limit == 100:
            args.limit = 1000

    params = {
        "subreddit": args.subreddit,
        "limit": args.limit
    }

    resp = requests.get(APEWISDOM_FILTERS[args.filter], params=params, timeout=30)
    if resp.status_code != 200:
        print(f"Error: ApeWisdom API returned HTTP {resp.status_code}", file=sys.stderr)
        print(resp.text[:200], file=sys.stderr)
        sys.exit(1)

    data = resp.json()
    results = data.get("results") or data.get("data") or []

    if not results:
        if args.json_output:
            print(json.dumps({"inserted": 0, "metrics": 0}))
        else:
            print("No results returned")
        return

    # For crypto, filter to Alpaca-tradeable symbols only
    tradeable = None
    if args.filter == "all-crypto":
        try:
            tradeable = fetch_tradeable_symbols("crypto")
        except Exception as exc:
            print(f"Warning: Could not fetch tradeable symbols, skipping filter: {exc}", file=sys.stderr)

    observed_at = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    metrics = []
    filtered_count = 0

    for row in results:
        raw_ticker = (row.get("ticker") or row.get("symbol") or "").upper().strip()
        if not raw_ticker:
            continue

        ticker = normalize_ticker(raw_ticker, args.filter)
        if tradeable is not None and ticker not in tradeable:
            filtered_count += 1
            continue
        if holdings is not None and ticker not in holdings:
            continue
        mentions = row.get("mentions") or row.get("count")
        if not ticker or mentions is None:
            continue
        try:
            mentions_val = float(mentions)
        except Exception:
            continue

        metrics.append({
            "ticker": ticker,
            "metric": f"social_mentions_{args.window}",
            "value": mentions_val,
            "source": "apewisdom",
            "observed_at": observed_at,
            "is_derived": False,
            "meta": {
                "subreddit": args.subreddit,
                "filter": args.filter,
                "rank": row.get("rank"),
                "apewisdom_ticker": raw_ticker,
                "mentions": row.get("mentions"),
                "score": row.get("score")
            }
        })

    if not metrics:
        if args.json_output:
            print(json.dumps({"inserted": 0, "metrics": 0}))
        else:
            print("No metrics to insert")
        return

    try:
        result = post_bulk_metrics(metrics)
    except requests.RequestException as e:
        print(f"Error posting metrics to Rails API: {e}", file=sys.stderr)
        sys.exit(1)

    if args.json_output:
        summary = {
            "inserted": result.get("inserted", 0),
            "metrics": len(metrics),
            "subreddit": args.subreddit,
            "filter": args.filter,
            "window": args.window,
            "holdings_only": bool(holdings),
        }
        if filtered_count:
            summary["filtered_untradeable"] = filtered_count
        print(json.dumps(summary))
    else:
        msg = f"Inserted {result.get('inserted', 0)} metrics for r/{args.subreddit}"
        if filtered_count:
            msg += f" ({filtered_count} untradeable tickers filtered)"
        print(msg)


if __name__ == "__main__":
    main()
