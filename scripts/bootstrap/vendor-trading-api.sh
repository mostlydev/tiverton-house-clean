#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
target_root="$repo_root/services/trading-api"
source_root="${TRADING_API_SOURCE_ROOT:-<upstream-trading-api-root>}"

usage() {
  cat <<'EOF'
Usage: vendor-trading-api.sh [--source /path/to/trading-api]

Sync the Rails app into services/trading-api without pulling in local state
or secrets. This is optional maintenance; the pod runs against the vendored
copy by default.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --source)
      source_root="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'unknown option: %s\n' "$1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ -z "$source_root" || ! -d "$source_root" ]]; then
  printf 'trading-api source checkout not found at %s\n' "$source_root" >&2
  exit 1
fi

mkdir -p "$target_root"

rsync -a --delete \
  --exclude='.git/' \
  --exclude='.github/' \
  --exclude='.opencode/' \
  --exclude='.env*' \
  --exclude='README.md' \
  --exclude='config/master.key' \
  --exclude='config/settings.local.yml' \
  --exclude='log/' \
  --exclude='tmp/' \
  --exclude='storage/' \
  "$source_root"/ "$target_root"/

mkdir -p \
  "$target_root/log" \
  "$target_root/storage" \
  "$target_root/tmp/pids" \
  "$target_root/tmp/storage"

touch \
  "$target_root/log/.keep" \
  "$target_root/storage/.keep" \
  "$target_root/tmp/.keep" \
  "$target_root/tmp/pids/.keep" \
  "$target_root/tmp/storage/.keep"

printf 'vendored trading-api from %s into %s\n' "$source_root" "$target_root"
