#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

required_files=(
  "$repo_root/.env.example"
  "$repo_root/README.md"
  "$repo_root/ARCHITECTURE.md"
  "$repo_root/POD-OPERATING-MODEL.md"
  "$repo_root/claw-pod.yml"
  "$repo_root/agents/_shared/OpenClawfile"
  "$repo_root/agents/_shared/OpenClawfile.trader"
  "$repo_root/agents/dundas/OpenClawfile"
  "$repo_root/docs/storage-layout.md"
  "$repo_root/docs/schedule-matrix.md"
  "$repo_root/docs/skills/desk-scripts.md"
  "$repo_root/scripts/README.md"
  "$repo_root/scripts/lib/claw.sh"
  "$repo_root/scripts/bootstrap/install-claw.sh"
  "$repo_root/scripts/audit/export-trade-audit.sh"
  "$repo_root/scripts/pod-down.sh"
  "$repo_root/scripts/pod-up.sh"
  "$repo_root/scripts/bootstrap/vendor-trading-api.sh"
  "$repo_root/services/trading-api/Dockerfile"
  "$repo_root/services/trading-api/docs/skills/trade.md"
  "$repo_root/services/trading-api/Gemfile"
  "$repo_root/services/trading-api/bin/rails"
  "$repo_root/services/trading-api/config/application.rb"
  "$repo_root/services/trading-api/config/initializers/rails_trail.rb"
  "$repo_root/agents/_shared/AGENTS.md"
  "$repo_root/agents/_shared/trader-base.md"
  "$repo_root/agents/_shared/coordinator-base.md"
  "$repo_root/agents/_shared/monitor-base.md"
  "$repo_root/agents/tiverton/IDENTITY.md"
  "$repo_root/agents/weston/IDENTITY.md"
  "$repo_root/agents/logan/IDENTITY.md"
  "$repo_root/agents/gerrard/IDENTITY.md"
  "$repo_root/agents/dundas/IDENTITY.md"
  "$repo_root/agents/sentinel/IDENTITY.md"
)

required_dirs=(
  "$repo_root/agents/tiverton"
  "$repo_root/agents/weston"
  "$repo_root/agents/logan"
  "$repo_root/agents/gerrard"
  "$repo_root/agents/dundas"
  "$repo_root/agents/_shared"
  "$repo_root/policy"
  "$repo_root/storage/shared"
  "$repo_root/storage/private/tiverton/memory"
  "$repo_root/storage/private/weston/memory"
  "$repo_root/storage/private/logan/memory"
  "$repo_root/storage/private/dundas/memory"
  "$repo_root/var/postgres"
  "$repo_root/var/redis"
  "$repo_root/scripts/bootstrap"
  "$repo_root/services/trading-api/app"
)

required_env=(
  OPENROUTER_API_KEY
  XAI_API_KEY
  POSTGRES_PASSWORD
  POSTGRES_DB
  REDIS_DATABASE
  RAILS_MASTER_KEY
  SECRET_KEY_BASE
  ALPACA_API_KEY
  ALPACA_SECRET_KEY
  DISCORD_GUILD_ID
  DISCORD_TRADING_FLOOR_CHANNEL
  DISCORD_INFRA_CHANNEL
  OPERATOR_DISCORD_ID
  LEVIATHAN_DISCORD_ID
  TIVERTON_DISCORD_ID
  WESTON_DISCORD_ID
  LOGAN_DISCORD_ID
  DUNDAS_DISCORD_ID
  GERRARD_DISCORD_ID
  SENTINEL_DISCORD_ID
  TRADING_API_INTERNAL_TOKEN
  DISCORD_TRADING_API_BOT_TOKEN
  TIVERTON_BOT_TOKEN
  TIVERTON_TRADING_API_TOKEN
  WESTON_BOT_TOKEN
  WESTON_TRADING_API_TOKEN
  LOGAN_BOT_TOKEN
  LOGAN_TRADING_API_TOKEN
  GERRARD_BOT_TOKEN
  GERRARD_TRADING_API_TOKEN
  DUNDAS_BOT_TOKEN
  DUNDAS_TRADING_API_TOKEN
  SENTINEL_DISCORD_BOT_TOKEN
  PERPLEXITY_KEY
)

missing=0

for file in "${required_files[@]}"; do
  if [[ ! -f "$file" ]]; then
    printf 'missing file: %s\n' "$file"
    missing=1
  fi
done

for dir in "${required_dirs[@]}"; do
  if [[ ! -d "$dir" ]]; then
    printf 'missing dir: %s\n' "$dir"
    missing=1
  fi
done

if [[ -f "$repo_root/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "$repo_root/.env"
  set +a
  for key in "${required_env[@]}"; do
    if [[ -z "${!key:-}" ]]; then
      printf 'missing env var in .env: %s\n' "$key"
      missing=1
    fi
  done
else
  printf '.env not present; skipped runtime env validation\n'
fi

if ! rg -q 'shared-agent: &shared_agent ./agents/_shared/AGENTS.md' "$repo_root/claw-pod.yml"; then
  printf 'claw-pod.yml does not point active agents at the shared AGENTS contract\n'
  missing=1
fi

if ! rg -q 'include:' "$repo_root/claw-pod.yml"; then
  printf 'claw-pod.yml is missing include blocks for identity/role context\n'
  missing=1
fi

if ! rg -q 'handles-defaults:' "$repo_root/claw-pod.yml"; then
  printf 'claw-pod.yml is missing pod-level x-claw handles-defaults for shared Discord topology\n'
  missing=1
fi

if ! rg -q 'x-trader-openclaw-service: &trader_openclaw_service' "$repo_root/claw-pod.yml"; then
  printf 'claw-pod.yml is missing the shared trader OpenClaw service anchor\n'
  missing=1
fi

if ! rg -q './agents/_shared/OpenClawfile' "$repo_root/claw-pod.yml"; then
  printf 'claw-pod.yml is not wiring shared agents to agents/_shared/OpenClawfile\n'
  missing=1
fi

if ! rg -q './agents/_shared/OpenClawfile.trader' "$repo_root/claw-pod.yml"; then
  printf 'claw-pod.yml is not wiring traders to agents/_shared/OpenClawfile.trader\n'
  missing=1
fi

if ! rg -q './agents/dundas/OpenClawfile' "$repo_root/claw-pod.yml"; then
  printf 'claw-pod.yml is not wiring dundas to agents/dundas/OpenClawfile\n'
  missing=1
fi

if ! rg -q 'DISCORD_ALLOWED_USERS:' "$repo_root/claw-pod.yml"; then
  printf 'claw-pod.yml is not exporting DISCORD_ALLOWED_USERS for Discord auth\n'
  missing=1
fi

if ! rg -q 'DISCORD_ALLOW_BOTS: "mentions"' "$repo_root/claw-pod.yml"; then
  printf 'claw-pod.yml is not exporting DISCORD_ALLOW_BOTS=mentions for agent-to-agent Discord traffic\n'
  missing=1
fi

if ! rg -q 'DESK_PUBLIC_ROOT:' "$repo_root/claw-pod.yml"; then
  printf 'claw-pod.yml is not exporting DESK_PUBLIC_ROOT for audit export and public staging\n'
  missing=1
fi

if ! rg -q 'DESK_SCRIPTS_ROOT:' "$repo_root/claw-pod.yml"; then
  printf 'claw-pod.yml is not exporting DESK_SCRIPTS_ROOT for wrapper self-discovery\n'
  missing=1
fi

if ! rg -q 'LEVIATHAN_DISCORD_ID' "$repo_root/claw-pod.yml"; then
  printf 'claw-pod.yml is missing Leviathan from the Discord admission allowlist\n'
  missing=1
fi

if ! rg -q 'name: market-context' "$repo_root/claw-pod.yml"; then
  printf 'claw-pod.yml is missing the market-context feed subscription\n'
  missing=1
fi

if ! rg -q 'desk-risk-context' "$repo_root/claw-pod.yml"; then
  printf 'claw-pod.yml is missing the desk-risk-context feed subscription\n'
  missing=1
fi

ruby_check_cmd=(ruby - "$repo_root/claw-pod.yml")
if ! command -v ruby >/dev/null 2>&1; then
  ruby_check_cmd=(
    docker run --rm -i
    -v "$repo_root:$repo_root:ro"
    -w "$repo_root"
    ruby:3.3-alpine
    ruby - "$repo_root/claw-pod.yml"
  )
fi

if ! "${ruby_check_cmd[@]}" <<'RUBY'
require "yaml"

path = ARGV.fetch(0)
doc = YAML.safe_load(File.read(path), aliases: true) || {}
services = doc.fetch("services", {})
default_guilds = doc.dig("x-claw", "handles-defaults", "discord", "guilds") || []
default_skills = doc.dig("x-claw", "skills-defaults") || []

expected_channels = {
  "tiverton" => ["trading-floor", "infra"],
  "weston" => ["trading-floor"],
  "logan" => ["trading-floor"],
  "gerrard" => ["trading-floor"],
  "dundas" => ["trading-floor"],
  "sentinel" => ["trading-floor", "infra"],
}

expected_skills = {
  "tiverton" => [
    "./docs/skills/desk-scripts.md",
    "./policy/risk-limits.md",
    "./policy/approval-workflow.md",
    "./policy/escalation.md",
  ],
  "weston" => [
    "./docs/skills/desk-scripts.md",
    "./policy/risk-limits.md",
    "./policy/approval-workflow.md",
  ],
  "logan" => [
    "./docs/skills/desk-scripts.md",
    "./policy/risk-limits.md",
    "./policy/approval-workflow.md",
  ],
  "gerrard" => [
    "./docs/skills/desk-scripts.md",
    "./policy/risk-limits.md",
    "./policy/approval-workflow.md",
  ],
  "dundas" => [
    "./docs/skills/desk-scripts.md",
    "./policy/risk-limits.md",
  ],
}

def channel_names(service_cfg, default_guilds)
  guilds = service_cfg.dig("x-claw", "handles", "discord", "guilds")
  guilds = default_guilds if guilds.nil? || guilds.empty?
  guilds.flat_map do |guild|
    Array(guild["channels"]).map { |channel| channel["name"] }
  end.compact.uniq.sort
end

def effective_skills(service_cfg, default_skills)
  skills = service_cfg.dig("x-claw", "skills")
  return default_skills.dup.sort if skills.nil?

  expanded = []
  Array(skills).each do |entry|
    if entry == "..."
      expanded.concat(default_skills)
    else
      expanded << entry
    end
  end
  expanded.uniq.sort
end

errors = []

expected_channels.each do |service, expected|
  actual = channel_names(services.fetch(service, {}), default_guilds)
  if actual != expected.sort
    errors << "#{service} discord channels #{actual.inspect} (expected #{expected.sort.inspect})"
  end
end

infra_services = services.each_with_object([]) do |(name, cfg), names|
  names << name if channel_names(cfg, default_guilds).include?("infra")
end.sort

if infra_services != ["sentinel", "tiverton"]
  errors << "infra channel topology is not limited to tiverton and sentinel (found #{infra_services.inspect})"
end

expected_skills.each do |service, expected|
  actual = effective_skills(services.fetch(service, {}), default_skills)
  if actual != expected.sort
    errors << "#{service} skills #{actual.inspect} (expected #{expected.sort.inspect})"
  end
end

unless errors.empty?
  errors.each do |error|
    warn "claw-pod.yml structural check failed: #{error}"
  end
  exit 1
end
RUBY
then
  missing=1
fi

if ! rg -q 'id: risk_limits' "$repo_root/claw-pod.yml"; then
  printf 'claw-pod.yml is missing the risk_limits include block\n'
  missing=1
fi

if ! rg -q 'id: approval_workflow' "$repo_root/claw-pod.yml"; then
  printf 'claw-pod.yml is missing the approval_workflow include block\n'
  missing=1
fi

if [[ -f "$repo_root/compose.generated.yml" ]]; then
  if ! rg -q '\.claw-runtime/.+/workspace:' "$repo_root/compose.generated.yml"; then
    printf 'compose.generated.yml is not mounting generated agent workspaces\n'
    missing=1
  fi

  for agent in tiverton weston logan gerrard dundas sentinel; do
    workspace_root="$repo_root/.claw-runtime/$agent/workspace"

    if [[ ! -d "$workspace_root" ]]; then
      printf 'missing generated workspace for %s in .claw-runtime\n' "$agent"
      missing=1
      continue
    fi

    if [[ ! -f "$workspace_root/AGENTS.md" ]]; then
      printf 'missing synthesized AGENTS.md for %s in workspace %s\n' "$agent" "$workspace_root"
      missing=1
    fi

    if [[ ! -f "$workspace_root/CLAWDAPUS.md" ]]; then
      printf 'missing synthesized CLAWDAPUS.md for %s in workspace %s\n' "$agent" "$workspace_root"
      missing=1
    fi
  done
fi

validate_json_file() {
  local path="$1"
  local filter="$2"

  if [[ -r "$path" ]]; then
    jq -e "$filter" "$path" >/dev/null
    return $?
  fi

  if command -v sudo >/dev/null 2>&1; then
    sudo -n cat "$path" 2>/dev/null | jq -e "$filter" >/dev/null
    return $?
  fi

  return 1
}

if command -v jq >/dev/null 2>&1; then
  schedule_manifest_filter='
    type == "object"
    and (.invocations | type == "array")
    and ([.invocations[]?.timezone] | all(. == env.TZ))
  '
  openclaw_cron_filter='
    type == "object"
    and (.version | type == "number")
    and (.jobs | type == "array")
    and ([.jobs[]? | select((.schedule | type) == "object" and .schedule.kind == "cron") | .schedule.tz] | all(. == env.TZ))
  '

  if ! validate_json_file "$repo_root/.claw-runtime/schedule.json" "$schedule_manifest_filter"; then
    printf 'schedule manifest is not normalized for desk timezone: %s\n' "$repo_root/.claw-runtime/schedule.json"
    missing=1
  fi

  shopt -s nullglob
  for jobs_path in \
    "$repo_root"/.claw-runtime/*/config/cron/jobs.json \
    "$repo_root"/.claw-runtime/*/state/cron/jobs.json
  do
    if ! validate_json_file "$jobs_path" "$openclaw_cron_filter"; then
      printf 'cron store is not normalized for openclaw gateway: %s\n' "$jobs_path"
      missing=1
    fi
  done
  shopt -u nullglob
fi

if [[ $missing -ne 0 ]]; then
  exit 1
fi

printf 'pod scaffold verification passed\n'
