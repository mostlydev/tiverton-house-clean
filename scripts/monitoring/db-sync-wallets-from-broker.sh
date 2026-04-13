#!/bin/bash
# Sync funded trader wallets from the latest Alpaca broker snapshot.
# Usage: db-sync-wallets-from-broker.sh [--refresh-snapshot] [--force] [--json]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/pod-env.sh
source "${SCRIPT_DIR}/../lib/pod-env.sh"

FORMAT="table"
FORCE=false
REFRESH_SNAPSHOT=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --json) FORMAT="json"; shift ;;
    --force) FORCE=true; shift ;;
    --refresh-snapshot) REFRESH_SNAPSHOT=true; shift ;;
    -*) echo "Unknown option: $1" >&2; exit 1 ;;
    *) echo "Unexpected argument: $1" >&2; exit 1 ;;
  esac
done

REQUEST_ARGS=()
if [[ "${FORCE}" == true ]]; then
  REQUEST_ARGS+=(--data-urlencode "force=true")
fi
if [[ "${REFRESH_SNAPSHOT}" == true ]]; then
  REQUEST_ARGS+=(--data-urlencode "refresh_snapshot=true")
fi

RESPONSE="$(trading_api_curl_with_status POST "/api/v1/operations/wallet_funding_sync" "${REQUEST_ARGS[@]}" 2>&1 || true)"
HTTP_CODE="$(echo "${RESPONSE}" | tail -n1)"
BODY="$(echo "${RESPONSE}" | head -n-1)"

if [[ -z "${HTTP_CODE}" ]]; then
  echo "Error: API unavailable" >&2
  exit 1
fi

if [[ "${FORMAT}" == "json" ]]; then
  echo "${BODY}" | jq '.'
  [[ "${HTTP_CODE}" == "200" ]] || exit 1
  exit 0
fi

if [[ "${HTTP_CODE}" != "200" ]]; then
  echo "${BODY}" | jq -r '.error // "Wallet funding sync failed"' >&2
  exit 1
fi

APPLIED="$(echo "${BODY}" | jq -r '.applied')"
if [[ "${APPLIED}" == "true" ]]; then
  SNAPSHOT_CAPITAL="$(echo "${BODY}" | jq -r '.snapshot_capital | tonumber')"
  echo "Wallet funding sync: applied"
  printf 'Snapshot capital: $%.2f\n' "${SNAPSHOT_CAPITAL}"
  echo "Funded traders:"
  echo "${BODY}" | jq -r '
    .allocations
    | to_entries
    | (["Agent", "Wallet", "Cash"]),
      (["-----", "------", "----"]),
      (.[] | [.key, (.value | tonumber | round), (.value | tonumber | round)])
    | @tsv
  ' | format_tsv_columns
else
  echo "Wallet funding sync: skipped"
  echo "${BODY}" | jq -r '.reason'
fi
