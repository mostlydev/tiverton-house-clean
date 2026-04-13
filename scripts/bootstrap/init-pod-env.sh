#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
trading_api_root="${TRADING_API_APP_ROOT:-$repo_root/services/trading-api}"
target_env="$repo_root/.env"
force=0

if [[ "${1:-}" == "--force" ]]; then
  force=1
fi

if [[ ! -d "$trading_api_root" ]]; then
  printf 'trading-api checkout not found at %s\n' "$trading_api_root" >&2
  exit 1
fi

if [[ -f "$target_env" && $force -ne 1 ]]; then
  printf '%s already exists; rerun with --force to replace it\n' "$target_env" >&2
  exit 1
fi

env_file="$trading_api_root/.env"
openclaw_config="/.openclaw/openclaw.json"

read_env_value() {
  local file="$1"
  local key="$2"
  [[ -f "$file" ]] || return 0
  awk -F= -v k="$key" '$1==k {sub($1"=", ""); print; exit}' "$file"
}

strip_wrapping_quotes() {
  local value="$1"
  if [[ "$value" == \"*\" && "$value" == *\" ]]; then
    value="${value:1:${#value}-2}"
  elif [[ "$value" == \'*\' && "$value" == *\' ]]; then
    value="${value:1:${#value}-2}"
  fi
  printf '%s' "$value"
}

generate_secret() {
  ruby -rsecurerandom -e 'puts SecureRandom.hex(32)'
}

env_or_file() {
  local key="$1"
  local value="${!key:-}"
  if [[ -z "$value" ]]; then
    value=$(read_env_value "$env_file" "$key")
  fi
  strip_wrapping_quotes "$value"
}

discord_token_for() {
  local account="$1"
  [[ -f "$openclaw_config" ]] || return 0
  ruby -rjson -e '
    j = JSON.parse(File.read(ARGV[0]))
    accounts = (((j["channels"] || {})["discord"] || {})["accounts"] || {})
    account = ARGV[1]
    puts((accounts[account] || {})["token"].to_s)
  ' "$openclaw_config" "$account"
}

discord_id_from_token() {
  local token="$1"
  [[ -n "$token" ]] || return 0
  ruby -rbase64 -e '
    token = ARGV[0].to_s
    segment = token.split(".", 2).first.to_s
    segment = segment.tr("-_", "+/")
    segment += "=" * ((4 - segment.length % 4) % 4)
    decoded = Base64.decode64(segment)
    puts(decoded) if decoded.match?(/\A\d+\z/)
  ' "$token"
}

secret_key_base="$(env_or_file SECRET_KEY_BASE)"
if [[ -z "$secret_key_base" ]]; then
  secret_key_base=$(ruby -rsecurerandom -e 'puts SecureRandom.hex(64)')
fi
trading_api_internal_token="$(env_or_file TRADING_API_INTERNAL_TOKEN)"
if [[ -z "$trading_api_internal_token" ]]; then
  trading_api_internal_token="$(generate_secret)"
fi
tiverton_trading_api_token="$(env_or_file TIVERTON_TRADING_API_TOKEN)"
if [[ -z "$tiverton_trading_api_token" ]]; then
  tiverton_trading_api_token="$(generate_secret)"
fi
weston_trading_api_token="$(env_or_file WESTON_TRADING_API_TOKEN)"
if [[ -z "$weston_trading_api_token" ]]; then
  weston_trading_api_token="$(generate_secret)"
fi
logan_trading_api_token="$(env_or_file LOGAN_TRADING_API_TOKEN)"
if [[ -z "$logan_trading_api_token" ]]; then
  logan_trading_api_token="$(generate_secret)"
fi
dundas_trading_api_token="$(env_or_file DUNDAS_TRADING_API_TOKEN)"
if [[ -z "$dundas_trading_api_token" ]]; then
  dundas_trading_api_token="$(generate_secret)"
fi
postgres_password="$(env_or_file POSTGRES_PASSWORD)"
alpaca_api_key="$(env_or_file ALPACA_API_KEY)"
alpaca_secret_key="$(env_or_file ALPACA_SECRET_KEY)"
alpaca_env="$(env_or_file ALPACA_ENV)"
alpaca_data_url="$(env_or_file ALPACA_DATA_URL)"
alpaca_data_endpoint_raw="$(env_or_file ALPACA_DATA_ENDPOINT)"
discord_floor_channel_id="$(env_or_file DISCORD_TRADING_FLOOR_CHANNEL_ID)"
discord_infra_channel_id="$(env_or_file DISCORD_INFRA_CHANNEL_ID)"
discord_user_mappings="$(env_or_file DISCORD_USER_MAPPINGS)"
discord_app_bot_token="$(env_or_file DISCORD_BOT_TOKEN)"
discord_trading_floor_webhook="$(env_or_file DISCORD_TRADING_FLOOR_WEBHOOK)"
discord_infra_webhook="$(env_or_file DISCORD_INFRA_WEBHOOK)"
discord_webhook="$(env_or_file DISCORD_TRADING_API_WEBHOOK)"

rails_master_key="${RAILS_MASTER_KEY:-}"
if [[ -z "$rails_master_key" && -f "$trading_api_root/config/master.key" ]]; then
  rails_master_key=$(tr -d '\n' < "$trading_api_root/config/master.key")
fi

floor_channel="${DISCORD_TRADING_FLOOR_CHANNEL:-$discord_floor_channel_id}"
infra_channel="${DISCORD_INFRA_CHANNEL:-$discord_infra_channel_id}"
alpaca_data_endpoint="${alpaca_data_endpoint_raw:-${alpaca_data_url:-https://data.alpaca.markets}}"
guild_id="${DISCORD_GUILD_ID:-}"
if [[ -z "$guild_id" && -f "<legacy-shared-root>/plans/production-migration-2026-03.md" ]]; then
  guild_id=$(rg -o 'DISCORD_GUILD_ID="?([0-9]+)"?' -r '$1' <legacy-shared-root>/plans/production-migration-2026-03.md | head -n 1 || true)
fi

mapped_discord_id() {
  local label="$1"
  DISCORD_USER_MAPPINGS_JSON="$discord_user_mappings" ruby -rjson -e '
    mappings = JSON.parse(ENV.fetch("DISCORD_USER_MAPPINGS_JSON", "{}"))
    label = ARGV.fetch(0)
    entry = mappings.find { |id, name| name.to_s.casecmp(label).zero? }
    puts(entry ? entry.first : "")
  ' "$label"
}

mapped_discord_id_any() {
  local label
  local value
  for label in "$@"; do
    value="$(mapped_discord_id "$label")"
    if [[ -n "$value" ]]; then
      printf '%s\n' "$value"
      return 0
    fi
  done
  return 0
}

tiverton_discord_id="${TIVERTON_DISCORD_ID:-$(mapped_discord_id Tiverton)}"
weston_discord_id="${WESTON_DISCORD_ID:-${WESTIN_DISCORD_ID:-$(mapped_discord_id_any Weston Westin)}}"
logan_discord_id="${LOGAN_DISCORD_ID:-$(mapped_discord_id Logan)}"
dundas_discord_id="${DUNDAS_DISCORD_ID:-$(mapped_discord_id Dundas)}"
leviathan_discord_id="${LEVIATHAN_DISCORD_ID:-$(mapped_discord_id Leviathan)}"
if [[ -z "$leviathan_discord_id" ]]; then
  leviathan_discord_id="$(discord_id_from_token "$discord_app_bot_token")"
fi

tiverton_bot_token="${TIVERTON_BOT_TOKEN:-$(discord_token_for default)}"
weston_bot_token="${WESTON_BOT_TOKEN:-${WESTIN_BOT_TOKEN:-$(discord_token_for weston)}}"
if [[ -z "$weston_bot_token" ]]; then
  weston_bot_token="$(discord_token_for westin)"
fi
logan_bot_token="${LOGAN_BOT_TOKEN:-$(discord_token_for logan)}"
dundas_bot_token="${DUNDAS_BOT_TOKEN:-$(discord_token_for dundas)}"

umask 077
cat > "$target_env" <<ENVEOF
# Generated by scripts/bootstrap/init-pod-env.sh
POD_NAME=tiverton-house
TZ=${TZ:-America/New_York}

# LLM provider keys
OPENROUTER_API_KEY=${OPENROUTER_API_KEY:-}
ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY:-}

# Trading API runtime
RAILS_MASTER_KEY=${rails_master_key}
SECRET_KEY_BASE=${secret_key_base}
POSTGRES_PASSWORD=${postgres_password:-trading_dev_password}
POSTGRES_DB=tiverton_house_production
REDIS_DATABASE=5
BROKER_CUTOVER_AT=2026-03-09T00:00:00-04:00

# Broker / market integrations
ALPACA_API_KEY=${alpaca_api_key}
ALPACA_SECRET_KEY=${alpaca_secret_key}
ALPACA_ENV=${alpaca_env:-paper}
ALPACA_DATA_ENDPOINT=${alpaca_data_endpoint}
ALPACA_DATA_URL=${alpaca_data_url:-https://data.alpaca.markets}

# Discord server wiring
DISCORD_GUILD_ID=${guild_id}
DISCORD_TRADING_FLOOR_CHANNEL=${floor_channel}
DISCORD_INFRA_CHANNEL=${infra_channel}
DISCORD_TRADING_API_BOT_TOKEN=${discord_app_bot_token}
DISCORD_TRADING_FLOOR_WEBHOOK=${discord_trading_floor_webhook}
DISCORD_INFRA_WEBHOOK=${discord_infra_webhook}
OPERATOR_DISCORD_ID=${OPERATOR_DISCORD_ID:-}
LEVIATHAN_DISCORD_ID=${leviathan_discord_id}

# Public audit export / webhook integrations
DISCORD_TRADING_API_WEBHOOK=${discord_webhook}
TIVERTON_TRADES_GIT_REMOTE=${TIVERTON_TRADES_GIT_REMOTE:-}
TIVERTON_TRADES_BRANCH=${TIVERTON_TRADES_BRANCH:-main}
TRADING_API_INTERNAL_TOKEN=${trading_api_internal_token}

# Optional runtime path overrides for imported scripts
# Leave TRADING_API_APP_ROOT blank to use the vendored app at services/trading-api.
TRADING_API_APP_ROOT=
DESK_SHARED_ROOT=
DESK_PRIVATE_ROOT=
OPENCLAW_STATE_ROOT=
AGENT_WORKSPACES_ROOT=
TRADING_FLOOR_BOT_TOKEN=

# Agent Discord identities
TIVERTON_BOT_TOKEN=${tiverton_bot_token}
TIVERTON_DISCORD_ID=${tiverton_discord_id}
TIVERTON_TRADING_API_TOKEN=${tiverton_trading_api_token}
WESTON_BOT_TOKEN=${weston_bot_token}
WESTON_DISCORD_ID=${weston_discord_id}
WESTON_TRADING_API_TOKEN=${weston_trading_api_token}
LOGAN_BOT_TOKEN=${logan_bot_token}
LOGAN_DISCORD_ID=${logan_discord_id}
DUNDAS_BOT_TOKEN=${dundas_bot_token}
DUNDAS_DISCORD_ID=${dundas_discord_id}
LOGAN_TRADING_API_TOKEN=${logan_trading_api_token}
DUNDAS_TRADING_API_TOKEN=${dundas_trading_api_token}
ENVEOF

missing_keys=()
for key in \
  RAILS_MASTER_KEY \
  SECRET_KEY_BASE \
  ALPACA_API_KEY \
  ALPACA_SECRET_KEY \
  DISCORD_GUILD_ID \
  LEVIATHAN_DISCORD_ID \
  TIVERTON_BOT_TOKEN \
  TIVERTON_DISCORD_ID \
  TIVERTON_TRADING_API_TOKEN \
  WESTON_BOT_TOKEN \
  WESTON_DISCORD_ID \
  WESTON_TRADING_API_TOKEN \
  LOGAN_BOT_TOKEN \
  LOGAN_DISCORD_ID \
  LOGAN_TRADING_API_TOKEN \
  DUNDAS_BOT_TOKEN \
  DUNDAS_DISCORD_ID \
  DUNDAS_TRADING_API_TOKEN \
  TRADING_API_INTERNAL_TOKEN
do
  value=$(awk -F= -v k="$key" '$1==k {sub($1"=", ""); print; exit}' "$target_env")
  if [[ -z "$value" ]]; then
    missing_keys+=("$key")
  fi
done

printf 'wrote %s\n' "$target_env"
if [[ ${#missing_keys[@]} -gt 0 ]]; then
  printf 'still blank: %s\n' "${missing_keys[*]}"
fi
