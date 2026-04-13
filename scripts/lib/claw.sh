#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
repo_claw="$repo_root/.local-bin/claw"
install_script="$repo_root/scripts/bootstrap/install-claw.sh"

resolve_claw_bin() {
  if [[ -n "${CLAW_BIN:-}" ]]; then
    printf '%s\n' "$CLAW_BIN"
    return 0
  fi

  if [[ -x "$repo_claw" ]]; then
    printf '%s\n' "$repo_claw"
    return 0
  fi

  if command -v claw >/dev/null 2>&1; then
    command -v claw
    return 0
  fi

  printf 'missing claw binary; run %s\n' "$install_script" >&2
  return 1
}

ensure_repo_claw() {
  if [[ -n "${CLAW_BIN:-}" ]]; then
    return 0
  fi

  if [[ -x "$repo_claw" ]]; then
    return 0
  fi

  "$install_script"
}
