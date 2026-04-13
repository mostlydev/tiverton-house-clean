#!/bin/bash
# Align ledger positions/cash to Alpaca.
# Usage: db-align-alpaca.sh [--apply] [--positions] [--cash] [--qty-tolerance=...] [--cash-tolerance=...]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/pod-env.sh
source "${SCRIPT_DIR}/../lib/pod-env.sh"

API_URL="${TRADING_API_BASE_URL}/api/v1/operations/alpaca_align"
APPLY=0
POSITIONS=0
CASH=0
QTY_TOLERANCE="0.0001"
CASH_TOLERANCE="5.0"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply)
      APPLY=1
      shift
      ;;
    --positions)
      POSITIONS=1
      shift
      ;;
    --cash)
      CASH=1
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

if [[ "${APPLY}" -eq 1 ]]; then
  REQUEST_ARGS+=(--data-urlencode "apply=true")
fi

if [[ "${POSITIONS}" -eq 1 ]]; then
  REQUEST_ARGS+=(--data-urlencode "positions=true")
fi

if [[ "${CASH}" -eq 1 ]]; then
  REQUEST_ARGS+=(--data-urlencode "cash=true")
fi

RESPONSE="$(curl -sS -w "\n%{http_code}" -X POST "${REQUEST_ARGS[@]}" "${API_URL}" 2>&1 || true)"
STATUS_CODE="$(printf '%s\n' "${RESPONSE}" | tail -n1)"
BODY="$(printf '%s\n' "${RESPONSE}" | sed '$d')"

if [[ ! "${STATUS_CODE}" =~ ^[0-9]{3}$ ]]; then
  echo "Error: API unavailable (curl failed)" >&2
  echo "Attempted to connect to: ${API_URL}" >&2
  [[ -n "${RESPONSE}" ]] && echo "${RESPONSE}" >&2
  exit 1
fi

if command -v jq >/dev/null 2>&1 && echo "${BODY}" | jq -e . >/dev/null 2>&1; then
  echo "${BODY}" | jq '.'
else
  printf '%s\n' "${BODY}"
fi

case "${STATUS_CODE}" in
  200)
    exit 0
    ;;
  422)
    exit 2
    ;;
  *)
    exit 1
    ;;
esac
