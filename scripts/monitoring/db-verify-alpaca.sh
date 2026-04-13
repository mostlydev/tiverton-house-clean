#!/bin/bash
# Verify Alpaca positions/cash vs the active accounting source.
# Usage: db-verify-alpaca.sh [--positions-only|--cash-only] [--qty-tolerance=...] [--cash-tolerance=...] [--json]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/pod-env.sh
source "${SCRIPT_DIR}/../lib/pod-env.sh"

API_URL="${TRADING_API_BASE_URL}/api/v1/operations/alpaca_consistency"
QTY_TOLERANCE="0.0001"
CASH_TOLERANCE="5.0"
POSITIONS_ONLY=0
CASH_ONLY=0
JSON_OUTPUT=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --positions-only)
      POSITIONS_ONLY=1
      shift
      ;;
    --cash-only)
      CASH_ONLY=1
      shift
      ;;
    --qty-tolerance=*)
      QTY_TOLERANCE="${1#*=}"
      shift
      ;;
    --cash-tolerance=*)
      CASH_TOLERANCE="${1#*=}"
      shift
      ;;
    --json)
      JSON_OUTPUT=1
      shift
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

REQUEST_ARGS=(
  --data-urlencode "qty_tolerance=${QTY_TOLERANCE}"
  --data-urlencode "cash_tolerance=${CASH_TOLERANCE}"
)

if [[ "${POSITIONS_ONLY}" -eq 1 ]]; then
  REQUEST_ARGS+=(--data-urlencode "positions_only=true")
fi

if [[ "${CASH_ONLY}" -eq 1 ]]; then
  REQUEST_ARGS+=(--data-urlencode "cash_only=true")
fi

RESPONSE="$(trading_api_curl_with_status POST "/api/v1/operations/alpaca_consistency" "${REQUEST_ARGS[@]}" 2>&1 || true)"
STATUS_CODE="$(printf '%s\n' "${RESPONSE}" | tail -n1)"
BODY="$(printf '%s\n' "${RESPONSE}" | sed '$d')"

if [[ ! "${STATUS_CODE}" =~ ^[0-9]{3}$ ]]; then
  echo "Error: API unavailable (curl failed)" >&2
  echo "Attempted to connect to: ${API_URL}" >&2
  [[ -n "${RESPONSE}" ]] && echo "${RESPONSE}" >&2
  exit 1
fi

print_json() {
  if command -v jq >/dev/null 2>&1 && echo "${BODY}" | jq -e . >/dev/null 2>&1; then
    echo "${BODY}" | jq '.'
  else
    printf '%s\n' "${BODY}"
  fi
}

print_human() {
  if ! command -v jq >/dev/null 2>&1 || ! echo "${BODY}" | jq -e . >/dev/null 2>&1; then
    printf '%s\n' "${BODY}"
    return
  fi

  local overall
  overall="$(echo "${BODY}" | jq -r 'if .ok then "OK" else "FAIL" end')"
  echo "Alpaca consistency check: ${overall}"

  if [[ "$(echo "${BODY}" | jq -r '.positions != null')" == "true" ]]; then
    echo "${BODY}" | jq -r '
      "  Positions: " + (if .positions.ok then "OK" else "FAIL" end) +
      " (alpaca=" + (.positions.alpaca_count | tostring) +
      ", ledger=" + (.positions.ledger_count | tostring) + ")"'

    if [[ "$(echo "${BODY}" | jq '.positions.mismatches | length')" != "0" ]]; then
      echo "${BODY}" | jq -r '
        .positions.mismatches[] |
        "    " + .ticker + ": alpaca=" + (.alpaca_qty | tostring) +
        " ledger=" + (.ledger_qty | tostring) +
        " diff=" + (.diff | tostring)'
    fi
  fi

  if [[ "$(echo "${BODY}" | jq -r '.cash != null')" == "true" ]]; then
    if [[ "$(echo "${BODY}" | jq -r '.cash.ok')" == "true" ]]; then
      local cash_source internal_cash alpaca_cash cash_diff
      IFS=$'\t' read -r cash_source internal_cash alpaca_cash cash_diff < <(
        echo "${BODY}" | jq -r '[.cash.cash_source, (.cash.internal_cash // .cash.ledger_cash), .cash.alpaca_cash, .cash.diff] | @tsv'
      )
      printf '  Cash: OK (%s=%.2f alpaca=%.2f diff=%.2f)\n' \
        "${cash_source}" "${internal_cash}" "${alpaca_cash}" "${cash_diff}"
    else
      local cash_error
      cash_error="$(echo "${BODY}" | jq -r '.cash.error // empty')"
      if [[ -n "${cash_error}" ]]; then
        echo "  Cash: FAIL (${cash_error})"
      else
        echo "  Cash: FAIL (diff too large)"
      fi
    fi
  fi
}

case "${STATUS_CODE}" in
  200)
    if [[ "${JSON_OUTPUT}" -eq 1 ]]; then
      print_json
    else
      print_human
    fi
    exit 0
    ;;
  422)
    if [[ "${JSON_OUTPUT}" -eq 1 ]]; then
      print_json
    else
      print_human
    fi
    exit 2
    ;;
  *)
    if [[ "${JSON_OUTPUT}" -eq 1 ]]; then
      print_json
    elif command -v jq >/dev/null 2>&1 && echo "${BODY}" | jq -e . >/dev/null 2>&1; then
      error_message="$(echo "${BODY}" | jq -r '.error // empty')"
      if [[ -n "${error_message}" ]]; then
        echo "Alpaca consistency check: ERROR (${error_message})"
      else
        echo "Alpaca consistency check: ERROR"
        echo "${BODY}" | jq '.'
      fi
    else
      printf '%s\n' "${BODY}"
    fi
    exit 1
    ;;
esac
