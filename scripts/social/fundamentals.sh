#!/bin/bash
# fundamentals.sh - Fetch fundamentals from ticker metrics store (API wrapper)
# Usage:
#   fundamentals.sh TICKER [--metrics a,b] [--period-type quarterly|annual|ttm] [--history] [--limit N] [--include-stale] [--json]
#
# API endpoint: GET /api/v1/ticker_metrics

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/pod-env.sh
source "${SCRIPT_DIR}/../lib/pod-env.sh"

TICKER=""
METRICS=""
PERIOD_TYPE=""
HISTORY=false
LIMIT=""
INCLUDE_STALE=false
FORMAT="table"

while [[ $# -gt 0 ]]; do
  case $1 in
    --metrics) METRICS="$2"; shift 2 ;;
    --period-type) PERIOD_TYPE="$2"; shift 2 ;;
    --history) HISTORY=true; shift ;;
    --limit) LIMIT="$2"; shift 2 ;;
    --include-stale) INCLUDE_STALE=true; shift ;;
    --json) FORMAT="json"; shift ;;
    -*) echo "Unknown option: $1" >&2; exit 1 ;;
    *) TICKER="$1"; shift ;;
  esac
done

if [[ -z "$TICKER" ]]; then
  echo "Usage: fundamentals.sh TICKER [--metrics a,b] [--period-type quarterly|annual|ttm] [--history] [--limit N] [--include-stale] [--json]" >&2
  exit 1
fi

QUERY="ticker=${TICKER}"
if [[ -n "$METRICS" ]]; then QUERY+="&metrics=${METRICS}"; fi
if [[ -n "$PERIOD_TYPE" ]]; then QUERY+="&period_type=${PERIOD_TYPE}"; fi
if [[ "$HISTORY" == true ]]; then QUERY+="&history=true"; fi
if [[ -n "$LIMIT" ]]; then QUERY+="&limit=${LIMIT}"; fi
if [[ "$INCLUDE_STALE" == true ]]; then QUERY+="&include_stale=true"; fi

RESPONSE=$(curl -s -w "\n%{http_code}" -X GET \
  "${API_BASE_URL}/api/v1/ticker_metrics?${QUERY}" 2>&1)

HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
BODY=$(echo "$RESPONSE" | head -n-1)

if [[ $? -ne 0 || -z "$HTTP_CODE" || "$HTTP_CODE" != "200" ]]; then
  echo "Error: API unavailable or request failed (HTTP $HTTP_CODE)" >&2
  echo "$BODY" >&2
  exit 1
fi

if [[ "$FORMAT" == "json" ]]; then
  echo "$BODY" | jq '.'
  exit 0
fi

METRICS_JSON=$(echo "$BODY" | jq '.metrics')
COUNT=$(echo "$METRICS_JSON" | jq 'length')

if [[ "$COUNT" == "0" || "$COUNT" == "null" ]]; then
  echo "No fundamentals metrics for $TICKER. Run: fetch-fundamentals.sh $TICKER"
  exit 0
fi

echo "=== Fundamentals: $TICKER ==="

echo "$METRICS_JSON" | jq -r '
  ["Metric", "Value", "Source", "Observed", "PeriodEnd", "Fresh"],
  ["------", "-----", "------", "--------", "---------", "-----"],
  (.[] | [
    .metric,
    (.value | tostring),
    .source,
    .observed_at,
    (.period_end // "-"),
    (.fresh | tostring)
  ]) | @tsv
' | format_tsv_columns
