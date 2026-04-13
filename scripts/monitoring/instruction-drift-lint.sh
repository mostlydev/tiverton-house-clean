#!/bin/bash
# instruction-drift-lint.sh - Catch instruction noise/drift before it causes bad turns.
# Usage: instruction-drift-lint.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/pod-env.sh
source "${SCRIPT_DIR}/../lib/pod-env.sh"

ROOT="$(pod_repo_root)"
MAX_CHARS=20000
PASS=0
WARN=0
FAIL=0

TARGETS=(
  "$ROOT/README.md"
)

# Include the shared contract, shared role blocks, and identity files used by the pod.
for f in "$ROOT"/agents/_shared/AGENTS.md "$ROOT"/agents/_shared/*.md "$ROOT"/agents/*/IDENTITY.md; do
  [[ -f "$f" ]] && TARGETS+=("$f")
done
for f in "$ROOT"/policy/*.md; do
  [[ -f "$f" ]] && TARGETS+=("$f")
done

note_pass() {
  echo "[PASS] $1"
  PASS=$((PASS + 1))
}

note_warn() {
  echo "[WARN] $1"
  WARN=$((WARN + 1))
}

note_fail() {
  echo "[FAIL] $1"
  FAIL=$((FAIL + 1))
}

echo "=== Instruction Drift Lint ==="
echo "Time: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
echo ""

for file in "${TARGETS[@]}"; do
  if [[ ! -f "$file" ]]; then
    note_warn "missing file: $file"
    continue
  fi

  chars=$(wc -m < "$file" | tr -d ' ')
  if (( chars > MAX_CHARS )); then
    note_fail "${file}: ${chars} chars (exceeds ${MAX_CHARS}; OpenClaw may truncate bootstrap context)"
  else
    note_pass "${file}: size ${chars} chars"
  fi

  if rg -n '\\n|\\t|\\r' "$file" >/tmp/instruction-lint-escapes.out 2>/dev/null; then
    hits=$(wc -l < /tmp/instruction-lint-escapes.out | tr -d ' ')
    note_warn "${file}: found ${hits} escaped-sequence artifact(s) (\\n/\\t/\\r)"
    sed -n '1,8p' /tmp/instruction-lint-escapes.out | sed 's/^/[INFO]   /'
  else
    note_pass "${file}: no escaped-sequence artifacts"
  fi

done

# Model-reference sanity check against configured OpenClaw model IDs.
python3 - <<'PY' > /tmp/instruction-lint-models.out
import json
import os
import re
from pathlib import Path

root = Path(os.environ["REPO_ROOT"])
available = set()

for clawfile in [root / "agents/_shared/OpenClawfile"]:
    text = clawfile.read_text(errors="ignore")
    for line in text.splitlines():
        line = line.strip()
        if line.startswith("MODEL "):
            parts = line.split()
            if len(parts) >= 3:
                available.add(parts[2])
                if "/" in parts[2]:
                    available.add(parts[2].split("/", 1)[1])

targets = [root / "README.md"]
targets.extend(sorted((root / "agents/_shared").glob("*.md")))
targets.extend(sorted(root.glob("agents/*/IDENTITY.md")))
targets.extend(sorted(root.glob("policy/*.md")))

pat = re.compile(r'\b(?:openrouter|x-ai|moonshotai|anthropic|openai)/[A-Za-z0-9._\-]+\b')
unknown = []

for path in targets:
    if not path.exists():
        continue
    text = path.read_text(errors='ignore')
    for match in pat.finditer(text):
        token = match.group(0)
        check = token
        if token.startswith('openrouter/'):
            check = token.split('/', 1)[1]
        if check not in available:
            unknown.append((str(path), token))

if not unknown:
    print('OK')
else:
    for path, token in unknown:
        print(f'{path}\t{token}')
PY

if [[ "$(cat /tmp/instruction-lint-models.out)" == "OK" ]]; then
  note_pass "model references in instructions align with configured model IDs"
else
  note_warn "found model references not present in current OpenClaw model catalog"
  sed -n '1,20p' /tmp/instruction-lint-models.out | sed 's/^/[INFO]   /'
fi

echo ""
echo "=== Summary ==="
echo "PASS=$PASS"
echo "WARN=$WARN"
echo "FAIL=$FAIL"

if (( FAIL > 0 )); then
  exit 1
fi

exit 0
