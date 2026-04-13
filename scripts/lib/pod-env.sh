#!/usr/bin/env bash

# Shared runtime helpers for pod-local desk scripts.
# These defaults preserve host compatibility while making pod-local service
# wiring and agent identity automatic when the right env vars are present.

set -o pipefail

export TRADING_DESK_POD_ENV_LOADED=1

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_ROOT="$(cd "${LIB_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${SCRIPTS_ROOT}/.." && pwd)"
ENV_FILE="${REPO_ROOT}/.env"

if [[ -z "${TRADING_DESK_POD_ENV_FILE_LOADED:-}" && -f "${ENV_FILE}" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
  set +a
  export TRADING_DESK_POD_ENV_FILE_LOADED=1
fi

export REPO_ROOT
export SCRIPTS_ROOT
export DESK_SCRIPTS_ROOT="${DESK_SCRIPTS_ROOT:-${SCRIPTS_ROOT}}"

export POD_NAME="${POD_NAME:-tiverton-house}"
export TRADING_API_BASE_URL="${TRADING_API_BASE_URL:-${API_BASE_URL:-http://trading-api:4000}}"
export API_BASE_URL="${TRADING_API_BASE_URL}"
export TRADING_API_APP_ROOT="${TRADING_API_APP_ROOT:-${REPO_ROOT}/services/trading-api}"
export TRADING_API_TOKEN="${TRADING_API_TOKEN:-${TRADING_API_INTERNAL_TOKEN:-}}"

export DESK_SHARED_ROOT="${DESK_SHARED_ROOT:-${REPO_ROOT}/storage/shared}"
export DESK_NEWS_ROOT="${DESK_NEWS_ROOT:-${DESK_SHARED_ROOT}/news}"
export DESK_REPORTS_ROOT="${DESK_REPORTS_ROOT:-${DESK_SHARED_ROOT}/reports}"
export DESK_CACHE_ROOT="${DESK_CACHE_ROOT:-${DESK_SHARED_ROOT}/cache}"
export DESK_LOGS_ROOT="${DESK_LOGS_ROOT:-${DESK_SHARED_ROOT}/logs}"
export DESK_RESEARCH_ROOT="${DESK_RESEARCH_ROOT:-${DESK_SHARED_ROOT}/research/tickers}"
export DESK_PUBLIC_ROOT="${DESK_PUBLIC_ROOT:-${DESK_SHARED_ROOT}/public}"

export DESK_PRIVATE_ROOT="${DESK_PRIVATE_ROOT:-${REPO_ROOT}/storage/private}"
export AGENT_PRIVATE_ROOT="${AGENT_PRIVATE_ROOT:-}"
export AGENT_MEMORY_ROOT="${AGENT_MEMORY_ROOT:-}"
export AGENT_NOTES_ROOT="${AGENT_NOTES_ROOT:-}"

export OPENCLAW_STATE_ROOT="${OPENCLAW_STATE_ROOT:-${HOME}/.openclaw}"
export OPENCLAW_CONFIG_PATH="${OPENCLAW_CONFIG_PATH:-${OPENCLAW_STATE_ROOT}/openclaw.json}"
export TIVERTON_TRADES_ROOT="${TIVERTON_TRADES_ROOT:-${DESK_PUBLIC_ROOT}}"
export TRADING_FLOOR_CHANNEL_ID="${TRADING_FLOOR_CHANNEL_ID:-${DISCORD_TRADING_FLOOR_CHANNEL:-}}"
export TRADING_INFRA_CHANNEL_ID="${TRADING_INFRA_CHANNEL_ID:-${DISCORD_INFRA_CHANNEL:-}}"

pod_repo_root() {
  printf '%s\n' "${REPO_ROOT}"
}

pod_script_root() {
  printf '%s\n' "${SCRIPTS_ROOT}"
}

pod_current_agent_id() {
  if [[ -n "${TRADING_AGENT_ID:-}" ]]; then
    printf '%s\n' "${TRADING_AGENT_ID}"
    return 0
  fi
  if [[ -n "${CLAW_HANDLE_DISCORD_USERNAME:-}" ]]; then
    printf '%s\n' "${CLAW_HANDLE_DISCORD_USERNAME}"
    return 0
  fi
  if [[ -n "${HOSTNAME:-}" ]]; then
    case "${HOSTNAME}" in
      tiverton*|weston*|logan*|gerrard*|dundas*|boulton*)
        printf '%s\n' "${HOSTNAME%%-*}"
        return 0
        ;;
    esac
  fi
  return 1
}

require_current_agent_id() {
  local agent
  agent="$(pod_current_agent_id 2>/dev/null || true)"
  if [[ -z "${agent}" ]]; then
    echo "Error: no implicit trading agent identity found. Set TRADING_AGENT_ID." >&2
    return 1
  fi
  printf '%s\n' "${agent}"
}

pod_agent_private_root() {
  local agent="$1"
  printf '%s\n' "${DESK_PRIVATE_ROOT}/${agent}"
}

pod_agent_memory_root() {
  local agent="${1:-}"
  if [[ -z "${agent}" ]]; then
    agent="$(require_current_agent_id)"
  fi
  printf '%s\n' "$(pod_agent_private_root "${agent}")/memory"
}

pod_agent_notes_root() {
  local agent="${1:-}"
  if [[ -z "${agent}" ]]; then
    agent="$(require_current_agent_id)"
  fi
  printf '%s\n' "$(pod_agent_private_root "${agent}")/notes"
}

trading_api_uses_pod_service_name() {
  case "${TRADING_API_BASE_URL%/}" in
    http://trading-api|https://trading-api|http://trading-api:*|https://trading-api:*)
      return 0
      ;;
  esac
  return 1
}

pod_trading_api_container_id() {
  if ! command -v docker >/dev/null 2>&1; then
    return 1
  fi

  docker ps -q \
    --filter "label=claw.pod=${POD_NAME}" \
    --filter "label=claw.service=trading-api" | head -n 1
}

trading_api_host_url() {
  if trading_api_uses_pod_service_name; then
    return 1
  fi

  printf '%s\n' "${TRADING_API_BASE_URL%/}"
}

trading_api_auth_header_args() {
  if [[ -n "${TRADING_API_TOKEN:-}" ]]; then
    printf '%s\n' "-H" "Authorization: Bearer ${TRADING_API_TOKEN}"
  fi
}

format_tsv_columns() {
  if command -v column >/dev/null 2>&1; then
    column -t -s $'\t'
  else
    cat
  fi
}

trading_api_curl() {
  local method="$1"
  local path="$2"
  shift 2

  local base_url="${TRADING_API_BASE_URL%/}"
  local auth_args=()
  local proto_args=()
  if [[ -n "${TRADING_API_TOKEN:-}" ]]; then
    auth_args=(-H "Authorization: Bearer ${TRADING_API_TOKEN}")
  fi
  if trading_api_uses_pod_service_name; then
    proto_args=(-H "X-Forwarded-Proto: https")
  fi
  local curl_args=(-sS "${auth_args[@]}" "${proto_args[@]}" -X "$method" "$@" "${base_url}${path}")

  if trading_api_uses_pod_service_name; then
    local container_id
    container_id="$(pod_trading_api_container_id)"
    if [[ -n "${container_id}" ]]; then
      curl_args=(-sS "${auth_args[@]}" -H "X-Forwarded-Proto: https" -X "$method" "$@" "http://127.0.0.1:4000${path}")
      docker exec "${container_id}" curl "${curl_args[@]}"
      return $?
    fi
  fi

  curl "${curl_args[@]}"
}

trading_api_curl_with_status() {
  local method="$1"
  local path="$2"
  shift 2

  local base_url="${TRADING_API_BASE_URL%/}"
  local auth_args=()
  local proto_args=()
  if [[ -n "${TRADING_API_TOKEN:-}" ]]; then
    auth_args=(-H "Authorization: Bearer ${TRADING_API_TOKEN}")
  fi
  if trading_api_uses_pod_service_name; then
    proto_args=(-H "X-Forwarded-Proto: https")
  fi
  local curl_args=(-sS "${auth_args[@]}" "${proto_args[@]}" -w "\n%{http_code}" -X "$method" "$@" "${base_url}${path}")

  if trading_api_uses_pod_service_name; then
    local container_id
    container_id="$(pod_trading_api_container_id)"
    if [[ -n "${container_id}" ]]; then
      curl_args=(-sS "${auth_args[@]}" -H "X-Forwarded-Proto: https" -w "\n%{http_code}" -X "$method" "$@" "http://127.0.0.1:4000${path}")
      docker exec "${container_id}" curl "${curl_args[@]}"
      return $?
    fi
  fi

  curl "${curl_args[@]}"
}

if [[ -z "${AGENT_PRIVATE_ROOT}" ]]; then
  current_agent="$(pod_current_agent_id 2>/dev/null || true)"
  if [[ -n "${current_agent}" ]]; then
    export AGENT_PRIVATE_ROOT="$(pod_agent_private_root "${current_agent}")"
  fi
fi

export AGENT_MEMORY_ROOT="${AGENT_MEMORY_ROOT:-${AGENT_PRIVATE_ROOT:+${AGENT_PRIVATE_ROOT}/memory}}"
export AGENT_NOTES_ROOT="${AGENT_NOTES_ROOT:-${AGENT_PRIVATE_ROOT:+${AGENT_PRIVATE_ROOT}/notes}}"

notify_discord_channel() {
  local target="$1"
  local message="$2"
  if [[ -z "${target}" ]]; then
    return 1
  fi
  if ! command -v openclaw >/dev/null 2>&1; then
    return 1
  fi
  openclaw message send --channel discord --target "${target}" --message "${message}" >/dev/null 2>&1
}
