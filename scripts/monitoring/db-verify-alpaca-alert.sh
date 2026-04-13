#!/bin/bash
# db-verify-alpaca-alert.sh - Verify Alpaca vs ledger and alert #infra on mismatch.
# Usage: db-verify-alpaca-alert.sh [--positions-only|--cash-only] [--qty-tolerance=...] [--cash-tolerance=...] [--json] [--no-notify]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/pod-env.sh
source "${SCRIPT_DIR}/../lib/pod-env.sh"

INFRA_CHANNEL="${TRADING_INFRA_CHANNEL_ID:-}"
QTY_TOL="0.01"
CASH_TOL="10"
JSON_OUTPUT=0
NOTIFY=1
POS_ONLY=0
CASH_ONLY=0

while [[ $# -gt 0 ]]; do
  case $1 in
    --positions-only) POS_ONLY=1; shift ;;
    --cash-only) CASH_ONLY=1; shift ;;
    --qty-tolerance=*) QTY_TOL="${1#*=}"; shift ;;
    --cash-tolerance=*) CASH_TOL="${1#*=}"; shift ;;
    --json) JSON_OUTPUT=1; shift ;;
    --no-notify) NOTIFY=0; shift ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

CMD=("${SCRIPT_DIR}/db-verify-alpaca.sh" "--qty-tolerance=${QTY_TOL}" "--cash-tolerance=${CASH_TOL}" "--json")
if [[ $POS_ONLY -eq 1 ]]; then
  CMD+=("--positions-only")
fi
if [[ $CASH_ONLY -eq 1 ]]; then
  CMD+=("--cash-only")
fi

set +e
# Add 30-second timeout to prevent hanging
OUTPUT=$(timeout 30s ${CMD[@]} 2>&1)
STATUS=$?
set -e

# Handle timeout specifically
if [[ $STATUS -eq 124 ]]; then
  STATUS=2
  OUTPUT='{"ok":false,"error":"Command timed out after 30 seconds"}'
fi

if [[ $JSON_OUTPUT -eq 1 ]]; then
  echo "$OUTPUT"
else
  if [[ $STATUS -eq 0 ]]; then
    echo "Alpaca consistency check: OK"
  else
    echo "Alpaca consistency check: FAIL"
  fi
fi

if [[ $STATUS -ne 0 && $NOTIFY -eq 1 ]]; then
  TS=$(date '+%Y-%m-%d %H:%M %Z')
  MSG="[ALPACA_MISMATCH] ${TS}"

  if command -v jq >/dev/null 2>&1; then
    if echo "$OUTPUT" | jq -e . >/dev/null 2>&1; then
      POS_SUMMARY=$(echo "$OUTPUT" | jq -r '
        if .positions == null then "" else
        "Positions: " + (if .positions.ok then "OK" else "FAIL" end) +
        " (alpaca=" + (.positions.alpaca_count|tostring) + ", ledger=" + (.positions.ledger_count|tostring) + ")" end')
      CASH_SUMMARY=$(echo "$OUTPUT" | jq -r '
        if .cash == null then "" else
        "Cash: " + (if .cash.ok then "OK" else "FAIL" end) +
        (if .cash.ok then " (diff=" + (.cash.diff|tostring) + ")" else
          (if .cash.error then " (" + .cash.error + ")" else "" end) end) end')

      MSG+="\n${POS_SUMMARY}"
      MSG+="\n${CASH_SUMMARY}"

      MISMATCH_LINES=$(echo "$OUTPUT" | jq -r '
        if .positions == null or .positions.mismatches == null then "" else
        .positions.mismatches | map("- " + .ticker + ": alpaca=" + (.alpaca_qty|tostring) + " ledger=" + (.ledger_qty|tostring) + " diff=" + (.diff|tostring)) | .[0:10] | join("\n") end')
      if [[ -n "$MISMATCH_LINES" ]]; then
        MSG+="\n"$'\n'"Top mismatches:"$'\n'"${MISMATCH_LINES}"
      fi
    else
      MSG+="\n${OUTPUT}"
    fi
  else
    MSG+="\n${OUTPUT}"
  fi

  notify_discord_channel "$INFRA_CHANNEL" "$MSG" || true
fi

exit $STATUS
