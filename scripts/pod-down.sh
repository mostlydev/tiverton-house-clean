#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck disable=SC1091
source "$repo_root/scripts/lib/claw.sh"

usage() {
  cat <<'EOF'
Usage: pod-down.sh [claw down args]

Stop and remove the trading desk pod from this repo.

Examples:
  ./scripts/pod-down.sh
  ./scripts/pod-down.sh --help
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

cd "$repo_root"
claw_bin=$(resolve_claw_bin)
exec "$claw_bin" down "$@"
