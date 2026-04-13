#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
env_file="$repo_root/.env"
cron_store_normalizer="$repo_root/scripts/bootstrap/normalize-openclaw-cron-stores.sh"
# shellcheck disable=SC1091
source "$repo_root/scripts/lib/claw.sh"

usage() {
  cat <<'EOF'
Usage: pod-up.sh [claw up args]

Launch or redeploy the trading desk pod with the repo-local .env file loaded
into the current shell so ambient exported variables do not override it. This
wrapper also prefers the repo-local claw binary and defaults to detached mode.

Examples:
  ./scripts/pod-up.sh
  ./scripts/pod-up.sh -d
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ ! -f "$env_file" ]]; then
  printf 'missing env file: %s\n' "$env_file" >&2
  exit 1
fi

repair_openclaw_configs() {
  local repaired=0
  local config tmp

  shopt -s nullglob
  for config in "$repo_root"/.claw-runtime/*/config/openclaw.json; do
    if [[ -w "$config" ]]; then
      continue
    fi

    tmp="${config}.tmp"
    install -m 600 /dev/null "$tmp"
    mv "$tmp" "$config"
    repaired=1
  done
  shopt -u nullglob

  if [[ "$repaired" -eq 1 ]]; then
    printf 'repaired stale .claw-runtime openclaw.json files before deploy\n'
  fi
}

repair_runtime_dir() {
  local runtime_dir="$repo_root/.claw-runtime"
  local uid gid

  [[ -d "$runtime_dir" ]] || return 0

  if ! find "$runtime_dir" \
    \( ! -user "$(id -un)" -o \( -type d \( -name 'AGENTS.generated.md' -o -name 'AGENTS.effective.md' \) \) \) \
    -print -quit | grep -q .; then
    return 0
  fi

  if ! command -v docker >/dev/null 2>&1; then
    printf 'docker is required to repair stale .claw-runtime ownership and shape\n' >&2
    return 1
  fi

  uid=$(id -u)
  gid=$(id -g)

  docker run --rm \
    -v "$runtime_dir:/mnt" \
    alpine sh -lc \
    "find /mnt -mindepth 1 -maxdepth 1 -exec rm -rf {} + && chown -R $uid:$gid /mnt"

  printf 'reset stale .claw-runtime before deploy\n'
}

cd "$repo_root"
repair_runtime_dir
repair_openclaw_configs

ensure_workspace_script_links() {
  local agents=(tiverton weston logan gerrard dundas)
  local workspace_root scripts_target link_path current_target
  local linked=0

  scripts_target="$repo_root/scripts"

  for agent in "${agents[@]}"; do
    for workspace_root in \
      "$repo_root/.claw-runtime/$agent/workspace" \
      "$repo_root/.claw-state/$agent/workspace"
    do
      [[ -d "$workspace_root" ]] || continue

      link_path="$workspace_root/scripts"
      if [[ -L "$link_path" ]]; then
        current_target=$(readlink "$link_path")
        [[ "$current_target" == "$scripts_target" ]] && continue
        rm -f "$link_path"
      elif [[ -e "$link_path" ]]; then
        printf 'workspace scripts path exists and is not a symlink: %s\n' "$link_path" >&2
        return 1
      fi

      ln -s "$scripts_target" "$link_path"
      linked=1
    done
  done

  if [[ "$linked" -eq 1 ]]; then
    printf 'ensured optional workspace scripts symlinks for Hermes agents\n'
  fi
}

set -a
# shellcheck disable=SC1090
source "$env_file"
set +a

ensure_repo_claw
claw_bin=$(resolve_claw_bin)
printf 'using claw binary: %s\n' "$claw_bin"

if [[ "$#" -eq 0 ]]; then
  set -- -d
elif [[ ! " $* " =~ (^|[[:space:]])-d($|[[:space:]]) && ! " $* " =~ (^|[[:space:]])--detach($|[[:space:]]) ]]; then
  set -- -d "$@"
fi

"$claw_bin" up "$@"
ensure_workspace_script_links

cron_store_changed=0
if [[ -x "$cron_store_normalizer" ]]; then
  if "$cron_store_normalizer"; then
    :
  else
    status=$?
    if [[ "$status" -eq 10 ]]; then
      cron_store_changed=1
    else
      exit "$status"
    fi
  fi
fi

if [[ "$cron_store_changed" -eq 1 ]]; then
  printf 'restarting scheduler, UI, and agent containers to pick up normalized runtime timezones\n'
  docker compose -p "${POD_NAME:-tiverton-house}" -f "$repo_root/compose.generated.yml" restart \
    claw-api clawdash allen dundas gerrard logan sentinel tiverton weston >/dev/null
fi
