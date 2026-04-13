#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
install_dir="$repo_root/.local-bin"
install_path="$install_dir/claw"
version="${1:-${CLAWDAPUS_VERSION:-v0.2.2}}"

usage() {
  cat <<'EOF'
Usage: install-claw.sh [version]

Build a repo-local claw binary from a tagged clawdapus release.

Examples:
  ./scripts/bootstrap/install-claw.sh
  ./scripts/bootstrap/install-claw.sh v0.2.2
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/clawdapus-install.XXXXXX")
trap 'rm -rf "$tmpdir"' EXIT

src_dir="$tmpdir/src"
git clone --branch "$version" --depth 1 https://github.com/mostlydev/clawdapus.git "$src_dir" >/dev/null
commit=$(git -C "$src_dir" rev-parse --short HEAD)

mkdir -p "$install_dir"
(
  cd "$src_dir"
  go build \
    -ldflags "-s -w -X main.version=$version -X main.commit=$commit" \
    -o "$install_path" \
    ./cmd/claw
)

printf 'installed claw %s (%s) to %s\n' "$version" "$commit" "$install_path"
