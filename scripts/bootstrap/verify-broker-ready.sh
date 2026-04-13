#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)

if [[ -f "$repo_root/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "$repo_root/.env"
  set +a
fi

: "${ALPACA_API_KEY:?ALPACA_API_KEY is required}"
: "${ALPACA_SECRET_KEY:?ALPACA_SECRET_KEY is required}"

alpaca_env="${ALPACA_ENV:-paper}"
case "$alpaca_env" in
  production) base_url="https://api.alpaca.markets" ;;
  *) base_url="https://paper-api.alpaca.markets" ;;
esac

workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT
account_json="$workdir/account.json"
positions_json="$workdir/positions.json"

curl -fsS \
  -H "APCA-API-KEY-ID: ${ALPACA_API_KEY}" \
  -H "APCA-API-SECRET-KEY: ${ALPACA_SECRET_KEY}" \
  "$base_url/v2/account" > "$account_json"

curl -fsS \
  -H "APCA-API-KEY-ID: ${ALPACA_API_KEY}" \
  -H "APCA-API-SECRET-KEY: ${ALPACA_SECRET_KEY}" \
  "$base_url/v2/positions" > "$positions_json"

ruby - "$account_json" "$positions_json" <<'RUBY'
require 'json'
account = JSON.parse(File.read(ARGV[0]))
positions = JSON.parse(File.read(ARGV[1]))
status = account['status'] || 'unknown'
non_flat = positions.select { |p| p['qty'].to_f.abs > 0.000001 }
puts "Broker account status: #{status}"
puts "Reported buying power: #{account['buying_power']}"
puts "Reported cash: #{account['cash']}"
puts "Open positions: #{non_flat.length}"
if non_flat.any?
  puts "Non-flat symbols: #{non_flat.map { |p| "#{p['symbol']}(#{p['qty']})" }.join(', ')}"
  exit 2
end
RUBY

if [[ -n "${BROKER_CUTOVER_AT:-}" ]]; then
  printf 'BROKER_CUTOVER_AT=%s\n' "$BROKER_CUTOVER_AT"
else
  printf 'WARN: BROKER_CUTOVER_AT is not set\n' >&2
fi

printf 'broker readiness check passed\n'
