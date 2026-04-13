#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
tz="${TZ:-America/New_York}"
changed=0

if ! command -v jq >/dev/null 2>&1; then
  printf 'jq is required to normalize OpenClaw cron stores\n' >&2
  exit 1
fi

normalize_schedule_manifest() {
  local manifest_path="$repo_root/.claw-runtime/schedule.json"
  local tmp_file

  [[ -f "$manifest_path" ]] || return 0

  tmp_file=$(mktemp)
  jq --arg tz "$tz" '
    if type != "object" then
      .
    else
      . + {version: (.version // 1)}
      | .invocations = ((.invocations // []) | map(
          if (.timezone // "") == "" or .timezone == "UTC" then
            . + {timezone: $tz}
          else
            .
          end
        ))
    end
  ' "$manifest_path" > "$tmp_file"

  if ! cmp -s "$tmp_file" "$manifest_path"; then
    mv "$tmp_file" "$manifest_path"
    printf 'normalized %s\n' "$manifest_path"
    changed=1
  else
    rm -f "$tmp_file"
  fi
}

normalize_schedule_manifest

normalize_schedule_state() {
  local manifest_path="$repo_root/.claw-runtime/schedule.json"
  local state_path="$repo_root/.claw-governance/schedule-state.json"
  local tmp_file

  [[ -f "$manifest_path" ]] || return 0
  [[ -f "$state_path" ]] || return 0

  tmp_file=$(mktemp)
  jq --slurpfile manifest "$manifest_path" '
    (($manifest[0].invocations // [])
      | map(select((.wake | type) == "object" and (
          ((.wake.adapter // "") | startswith("openclaw-agent-"))
          or (.wake.adapter // "") == "openclaw-exec"
        )) | .id)
    ) as $direct_ids
    | if type != "object" then
        .
      else
        . + {version: (.version // 1), invocations: (.invocations // {})}
        | .invocations |= with_entries(
            .key as $invocation_id
            | if ($direct_ids | index($invocation_id)) != null then
              .value |= (
                del(
                  .degraded,
                  .consecutive_failures,
                  .last_attempted_at,
                  .last_detail,
                  .last_evaluated_at,
                  .last_skipped_at
                )
                | .last_status = "scheduled"
              )
            else
              .
            end
          )
      end
  ' "$state_path" > "$tmp_file"

  if ! cmp -s "$tmp_file" "$state_path"; then
    mv "$tmp_file" "$state_path"
    printf 'normalized %s\n' "$state_path"
    changed=1
  else
    rm -f "$tmp_file"
  fi
}

normalize_schedule_state

shopt -s nullglob
for jobs_path in \
  "$repo_root"/.claw-runtime/*/config/cron/jobs.json \
  "$repo_root"/.claw-runtime/*/state/cron/jobs.json
do
  [[ -f "$jobs_path" ]] || continue

  source_path="$jobs_path"
  tmp_file=$(mktemp)
  scrubbed_file=""

  if ! jq -e . "$jobs_path" >/dev/null 2>&1; then
    scrubbed_file=$(mktemp)
    awk 'BEGIN { found = 0 } /^[[:space:]]*[\{\[]/ { found = 1 } found { print }' "$jobs_path" > "$scrubbed_file"
    if [[ -s "$scrubbed_file" ]] && jq -e . "$scrubbed_file" >/dev/null 2>&1; then
      source_path="$scrubbed_file"
    else
      rm -f "$tmp_file" "$scrubbed_file"
      printf 'failed to salvage invalid OpenClaw cron store: %s\n' "$jobs_path" >&2
      exit 1
    fi
  fi

  jq --arg tz "$tz" '
    def normalize_store:
      if type == "array" then
        {version: 1, jobs: .}
      elif type == "object" then
        . + {version: (.version // 1), jobs: (.jobs // [])}
      else
        {version: 1, jobs: []}
      end;

    normalize_store
    | .jobs |= map(
        .
        | .state = ((.state // {})
          | with_entries(select(.value != null and .value != 0 and .value != "")))
        | if (.schedule | type) == "object" and .schedule.kind == "cron" then
            .schedule |= (
              if (.tz // "") == "" or .tz == "UTC" then
                . + {tz: $tz}
              else
                .
              end
            )
          else
            .
          end
      )
  ' "$source_path" > "$tmp_file"

  if ! cmp -s "$tmp_file" "$jobs_path"; then
    mv "$tmp_file" "$jobs_path"
    printf 'normalized %s\n' "$jobs_path"
    changed=1
  else
    rm -f "$tmp_file"
  fi

  if [[ "$(stat -c '%a' "$jobs_path")" != "666" ]]; then
    chmod 666 "$jobs_path"
    printf 'fixed cron store permissions %s\n' "$jobs_path"
    changed=1
  fi

  rm -f "$scrubbed_file"
done
shopt -u nullglob

if [[ "$changed" -eq 1 ]]; then
  exit 10
fi

exit 0
