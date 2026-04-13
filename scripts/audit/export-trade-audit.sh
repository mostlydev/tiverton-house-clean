#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../lib/pod-env.sh"

output_path="${DESK_PUBLIC_ROOT%/}/trade-audit.json"
mkdir -p "${DESK_PUBLIC_ROOT}"

response="$(trading_api_curl_with_status GET "/api/v1/trade_events" 2>&1 || true)"
status_line="${response##*$'\n'}"
body="${response%$'\n'*}"

if [[ ! "${status_line}" =~ ^[0-9]{3}$ ]]; then
  printf 'audit export failed: malformed trading-api response\n%s\n' "${response}" >&2
  exit 1
fi

if [[ "${status_line}" != "200" ]]; then
  printf 'audit export failed: trading-api returned HTTP %s\n%s\n' "${status_line}" "${body}" >&2
  exit 1
fi

tmp_path="$(mktemp "${output_path}.tmp.XXXXXX")"
trap 'rm -f "${tmp_path}"' EXIT

if command -v jq >/dev/null 2>&1; then
  if ! printf '%s\n' "${body}" | jq -S . > "${tmp_path}"; then
    printf 'audit export failed: trading-api response was not valid JSON\n' >&2
    exit 1
  fi
else
  printf '%s\n' "${body}" > "${tmp_path}"
fi

chmod 0644 "${tmp_path}"
mv "${tmp_path}" "${output_path}"
chmod 0644 "${output_path}"
trap - EXIT

printf 'wrote %s\n' "${output_path}"
